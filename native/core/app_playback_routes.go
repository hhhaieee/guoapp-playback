package core

import (
	"context"
	"crypto/rand"
	"encoding/hex"
	"errors"
	"sort"
	"time"
)

type nativePlaybackChoice struct {
	source        string
	danmakuSource string
	danmakuSeries string
	danmakuVideo  string
	media         []ProviderMedia
	index         int
	qualities     []int
	streamSession string
	created       time.Time
}

func nativePlaybackChoices(media ProviderMedia, quality int) nativePlaybackChoice {
	choice := nativePlaybackChoice{qualities: []int{}}
	seen := map[string]bool{}
	qualities := map[int]bool{}
	for _, option := range append([]ProviderMedia{media}, media.Variants...) {
		if !IsProviderHTTPMediaURL(option.URL) {
			continue
		}
		identity := option.URL + "\x00" + option.Referer + "\x00" + hex.EncodeToString(option.CENCKey) + "\x00" + hex.EncodeToString(option.HLSKey)
		if seen[identity] {
			continue
		}
		seen[identity] = true
		option.Variants = nil
		choice.media = append(choice.media, option)
		if option.Quality > 0 {
			qualities[option.Quality] = true
		}
	}
	sort.SliceStable(choice.media, func(i, j int) bool { return choice.media[i].Quality > choice.media[j].Quality })
	for value := range qualities {
		choice.qualities = append(choice.qualities, value)
	}
	sort.Sort(sort.Reverse(sort.IntSlice(choice.qualities)))
	if quality > 0 && qualities[quality] {
		filtered := make([]ProviderMedia, 0, len(choice.media))
		for _, option := range choice.media {
			if option.Quality == quality {
				filtered = append(filtered, option)
			}
		}
		choice.media = filtered
	}
	return choice
}

func (engine *nativeEngine) streamServer() (*nativeStreamServer, error) {
	engine.mu.Lock()
	defer engine.mu.Unlock()
	if engine.stream == nil {
		stream, err := newNativeStreamServer(engine.downloader)
		if err != nil {
			return nil, err
		}
		engine.stream = stream
	}
	return engine.stream, nil
}

func (engine *nativeEngine) nativeOpenPlayback(ctx context.Context, choice nativePlaybackChoice) (nativePlan, error) {
	if err := ctx.Err(); err != nil {
		return nativePlan{}, err
	}
	if choice.index < 0 || choice.index >= len(choice.media) {
		return nativePlan{}, errors.New("该集没有其他可用的播放线路")
	}
	media := choice.media[choice.index]
	if !IsProviderHTTPMediaURL(media.URL) {
		return nativePlan{}, errors.New("站源未返回有效的播放地址")
	}
	tokenBytes := make([]byte, 24)
	if _, err := rand.Read(tokenBytes); err != nil {
		return nativePlan{}, errors.New("无法初始化播放会话")
	}
	plan := nativePlan{
		DanmakuID: choice.danmakuVideo,
		URL:       media.URL, Headers: map[string]string{"User-Agent": UserAgent, "Referer": media.Referer},
		Key: hex.EncodeToString(media.CENCKey), Quality: media.Quality, Qualities: choice.qualities,
		RouteIndex: choice.index, RouteCount: len(choice.media), Session: hex.EncodeToString(tokenBytes),
	}
	if media.Credentials != nil && !media.Credentials.Expires.IsZero() {
		if !time.Now().Before(media.Credentials.Expires) {
			return nativePlan{}, errors.New("播放凭证已过期，请重新解析播放")
		}
		plan.ExpiresAt = media.Credentials.Expires.UnixMilli()
	}
	stream, err := engine.streamServer()
	if err != nil {
		return nativePlan{}, err
	}
	plan.URL, choice.streamSession = stream.nativeOpen(choice.source, media)
	choice.created = time.Now()
	engine.mu.Lock()
	if engine.playbacks == nil {
		engine.playbacks = map[string]nativePlaybackChoice{}
	}
	var expired []string
	for token, old := range engine.playbacks {
		if time.Since(old.created) > 12*time.Hour {
			expired = append(expired, old.streamSession)
			delete(engine.playbacks, token)
		}
	}
	if len(engine.playbacks) >= 8 {
		oldest := ""
		for token, old := range engine.playbacks {
			if oldest == "" || old.created.Before(engine.playbacks[oldest].created) {
				oldest = token
			}
		}
		expired = append(expired, engine.playbacks[oldest].streamSession)
		delete(engine.playbacks, oldest)
	}
	engine.playbacks[plan.Session] = choice
	engine.mu.Unlock()
	for _, token := range expired {
		stream.nativeRelease(token)
	}
	if err := ctx.Err(); err != nil {
		engine.nativeReleasePlayback(plan.Session)
		return nativePlan{}, err
	}
	return plan, nil
}

func (engine *nativeEngine) nativeNextPlayback(ctx context.Context, session string) (nativePlan, error) {
	engine.mu.Lock()
	choice, exists := engine.playbacks[session]
	engine.mu.Unlock()
	if !exists {
		return nativePlan{}, errors.New("播放线路已失效，请重新解析播放")
	}
	choice.index++
	return engine.nativeOpenPlayback(ctx, choice)
}

func (engine *nativeEngine) nativeReleasePlayback(session string) {
	engine.mu.Lock()
	choice, exists := engine.playbacks[session]
	delete(engine.playbacks, session)
	stream := engine.stream
	engine.mu.Unlock()
	if exists && stream != nil && choice.streamSession != "" {
		stream.nativeRelease(choice.streamSession)
	}
}

// nativePipStream 为 iOS 系统画中画准备一个独立、已解密的本地流地址。
// 普通播放时 libmpv 依赖 decryption_key 参数自行解密，但画中画的 AVPlayer
// 无法解密，因此需要流服务器输出解密后的 mp4（复用投屏的解密路径）。
func (engine *nativeEngine) nativePipStream(ctx context.Context, input nativeInput) (nativePlan, error) {
	engine.mu.Lock()
	choice, exists := engine.playbacks[input.Session]
	engine.mu.Unlock()
	if !exists {
		return nativePlan{}, errors.New("播放会话已失效，请重新播放后再试画中画")
	}
	if choice.index < 0 || choice.index >= len(choice.media) {
		return nativePlan{}, errors.New("当前播放线路无效")
	}
	media := choice.media[choice.index]
	if !IsProviderHTTPMediaURL(media.URL) {
		return nativePlan{}, errors.New("站源未返回有效的播放地址")
	}
	stream, err := engine.streamServer()
	if err != nil {
		return nativePlan{}, err
	}
	url, token := stream.nativeOpen(choice.source, media)
	if len(media.CENCKey) > 0 {
		if err := stream.nativeDecrypt(ctx, token, media); err != nil {
			stream.nativeRelease(token)
			return nativePlan{}, err
		}
	}
	return nativePlan{
		URL:     url,
		Headers: map[string]string{"User-Agent": UserAgent, "Referer": media.Referer},
		Session: token,
	}, nil
}
