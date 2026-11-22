package core

import (
	"bytes"
	"context"
	"crypto/rand"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net/http"
	"os"
	"path/filepath"
	"regexp"
	"runtime"
	"strconv"
	"strings"
)

var nativeUpdateServer = ""

var nativeProjectURL = ""

var nativeAppVersionPattern = regexp.MustCompile(`^\d+\.\d+\.\d+\+(\d+)$`)
var nativeInstallIDPattern = regexp.MustCompile(`^[0-9a-f]{32}$`)

type nativeUpdate struct {
	Available bool   `json:"available"`
	Version   string `json:"version,omitempty"`
	URL       string `json:"url,omitempty"`
}

func nativeUpdateServers() []string {
	servers := []string{}
	for _, server := range strings.Split(nativeUpdateServer, ",") {
		if server = strings.TrimRight(strings.TrimSpace(server), "/"); server != "" {
			servers = append(servers, server)
		}
	}
	return servers
}

func nativeReleasePrefix() string {
	project := strings.TrimRight(strings.TrimSpace(nativeProjectURL), "/")
	if project == "" {
		return ""
	}
	return project + "/releases/"
}

// nativeProjectOwnerRepo 从 nativeProjectURL（形如 https://github.com/owner/repo）
// 解析出 owner 与 repo，用于直接请求 GitHub Releases API。
func nativeProjectOwnerRepo() (string, string) {
	project := strings.TrimRight(strings.TrimSpace(nativeProjectURL), "/")
	project = strings.TrimPrefix(strings.TrimPrefix(project, "https://"), "http://")
	parts := strings.Split(project, "/")
	if len(parts) >= 3 && parts[0] == "github.com" {
		return parts[1], parts[2]
	}
	return "", ""
}

func nativeAppBuildSlug() string { return "guoapp" }

func nativeAppBuildNumber(version string) (int, bool) {
	match := nativeAppVersionPattern.FindStringSubmatch(version)
	if match == nil {
		return 0, false
	}
	number, err := strconv.Atoi(match[1])
	return number, err == nil
}

func (engine *nativeEngine) installID() (string, error) {
	path := filepath.Join(engine.directory, "install-id")
	if data, err := os.ReadFile(path); err == nil && nativeInstallIDPattern.Match(data) {
		return string(data), nil
	}
	buffer := make([]byte, 16)
	if _, err := rand.Read(buffer); err != nil {
		return "", err
	}
	id := hex.EncodeToString(buffer)
	return id, os.WriteFile(path, []byte(id), 0600)
}

func (engine *nativeEngine) reportUsage(ctx context.Context, version string) error {
	if _, valid := nativeAppBuildNumber(version); !valid {
		return errors.New("应用版本号无效")
	}
	servers := nativeUpdateServers()
	if len(servers) == 0 {
		return nil
	}
	id, err := engine.installID()
	if err != nil {
		return err
	}
	payload, err := json.Marshal(map[string]string{"id": id, "version": version, "platform": runtime.GOOS, "build": nativeAppBuildSlug()})
	if err != nil {
		return err
	}
	for _, server := range servers {
		if err = engine.postUsage(ctx, server, payload); err == nil || ctx.Err() != nil {
			return err
		}
	}
	return err
}

func (engine *nativeEngine) postUsage(ctx context.Context, server string, payload []byte) error {
	request, err := http.NewRequestWithContext(ctx, http.MethodPost, server+"/v1/ping", bytes.NewReader(payload))
	if err != nil {
		return err
	}
	request.Header.Set("Content-Type", "application/json")
	response, err := engine.downloader.client.Do(request)
	if err != nil {
		return err
	}
	response.Body.Close()
	if response.StatusCode/100 != 2 {
		return fmt.Errorf("使用统计失败：HTTP %d", response.StatusCode)
	}
	return nil
}

func (engine *nativeEngine) checkUpdate(ctx context.Context, version string) (nativeUpdate, error) {
	current, valid := nativeAppBuildNumber(version)
	if !valid {
		return nativeUpdate{}, errors.New("应用版本号无效")
	}
	// 直接检测本项目 GitHub 最新 Release，不再依赖自建更新服务器。
	owner, repo := nativeProjectOwnerRepo()
	if owner == "" || repo == "" {
		return nativeUpdate{}, errors.New("这个安装包没有配置项目地址，无法检查更新")
	}
	latest, err := engine.fetchGithubLatest(ctx, owner, repo)
	if err != nil {
		return nativeUpdate{}, err
	}
	number, valid := nativeAppBuildNumber(latest.Version)
	if !valid {
		return nativeUpdate{}, errors.New("项目最新发布没有返回有效的版本号")
	}
	if number <= current {
		return nativeUpdate{}, nil
	}
	return latest, nil
}

func (engine *nativeEngine) fetchLatest(ctx context.Context, server string) (nativeUpdate, error) {
	request, err := http.NewRequestWithContext(ctx, http.MethodGet, server+"/v1/latest", nil)
	if err != nil {
		return nativeUpdate{}, err
	}
	response, err := engine.downloader.client.Do(request)
	if err != nil {
		return nativeUpdate{}, err
	}
	defer response.Body.Close()
	if response.StatusCode != http.StatusOK {
		return nativeUpdate{}, fmt.Errorf("检查更新失败：HTTP %d", response.StatusCode)
	}
	var latest nativeUpdate
	return latest, json.NewDecoder(io.LimitReader(response.Body, 4096)).Decode(&latest)
}

// fetchGithubLatest 直接请求 GitHub Releases API 获取本项目最新发布，解析
// 形如 `app-vX.Y.Z-NNN` 的 tag，得到版本号与发布页地址。
func (engine *nativeEngine) fetchGithubLatest(ctx context.Context, owner, repo string) (nativeUpdate, error) {
	url := fmt.Sprintf("https://api.github.com/repos/%s/%s/releases/latest", owner, repo)
	request, err := http.NewRequestWithContext(ctx, http.MethodGet, url, nil)
	if err != nil {
		return nativeUpdate{}, err
	}
	request.Header.Set("Accept", "application/vnd.github+json")
	request.Header.Set("User-Agent", "guoapp-update")
	response, err := engine.downloader.client.Do(request)
	if err != nil {
		return nativeUpdate{}, err
	}
	defer response.Body.Close()
	if response.StatusCode != http.StatusOK {
		return nativeUpdate{}, fmt.Errorf("检查更新失败：HTTP %d", response.StatusCode)
	}
	var release struct {
		TagName string `json:"tag_name"`
		HTMLURL string `json:"html_url"`
	}
	if err := json.NewDecoder(io.LimitReader(response.Body, 1<<20)).Decode(&release); err != nil {
		return nativeUpdate{}, err
	}
	match := regexp.MustCompile(`^app-v(\d+\.\d+\.\d+)-(\d+)$`).FindStringSubmatch(release.TagName)
	if match == nil {
		return nativeUpdate{}, errors.New("项目最新发布的标签格式不正确")
	}
	version := match[1] + "+" + match[2]
	htmlURL := release.HTMLURL
	if htmlURL == "" {
		htmlURL = nativeReleasePrefix() + release.TagName
	}
	return nativeUpdate{Available: true, Version: version, URL: htmlURL}, nil
}
