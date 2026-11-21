package core

import (
	"net/url"
	"strconv"
	"strings"
)

// 片源插播广告过滤。
//
// 在 m3u8 改写阶段剔除插播广告分段，同时不破坏正片的分段标记结构。
// 识别规则（满足任一即视为广告分段）：
//  1. 分段地址带 adjump / ad-jump / adtag / /ad/ 等广告跳转标记；
//  2. 异域名短分段：域名与播放列表主域名不同，且时长不超过 adMaxShortSeconds；
//  3. AES 加密片源中的明文短分段：播放列表声明 AES-128/SAMPLE-AES，但当前分段
//     未被任何 KEY 覆盖（METHOD=NONE 或 KEY 缺失），且时长很短；
//  4. 重复分段：与上一个保留分段地址完全相同且时长很短（连续重复插播）。
//
// 过滤时只移除广告分段紧邻的 #EXTINF 行与该分段地址行，保留 VERSION / KEY /
// MAP / TARGETDURATION 等全部结构标签，避免误伤正片。若过滤比例过高（>40%）
// 视为误判，放弃过滤整份列表。

const adMaxShortSeconds = 15.0

type adSegment struct {
	uri      string
	duration float64
}

// stripAdsFromPlaylist 对 m3u8 文本做广告分段过滤，base 为播放列表地址，用于判断异域名。
func stripAdsFromPlaylist(body, base string) string {
	lines := strings.Split(strings.ReplaceAll(body, "\r\n", "\n"), "\n")
	baseHost := ""
	if parsed, err := url.Parse(base); err == nil {
		baseHost = strings.ToLower(parsed.Hostname())
	}

	isAd := func(seg adSegment, prevURI string, plainWhileEncrypted bool) bool {
		lower := strings.ToLower(seg.uri)
		if strings.Contains(lower, "adjump") ||
			strings.Contains(lower, "ad-jump") ||
			strings.Contains(lower, "adtag") ||
			strings.Contains(lower, "/ad/") {
			return true
		}
		host := ""
		if parsed, err := url.Parse(seg.uri); err == nil {
			host = strings.ToLower(parsed.Hostname())
		}
		short := seg.duration > 0 && seg.duration <= adMaxShortSeconds
		if baseHost != "" && host != "" && host != baseHost && short {
			return true
		}
		if plainWhileEncrypted && short {
			return true
		}
		if prevURI != "" && seg.uri == prevURI && short {
			return true
		}
		return false
	}

	var kept []string
	encrypted := false
	keyActive := false
	pendingExtInf := -1 // kept 中当前分段 EXTINF 行的下标
	prevURI := ""
	inSegments := false
	dropped := 0
	keptSegments := 0

	for _, line := range lines {
		text := strings.TrimSpace(line)
		if text == "" {
			kept = append(kept, line)
			continue
		}
		if strings.HasPrefix(text, "#EXT-X-KEY:") {
			method := playlistAttr(text, "METHOD")
			if strings.EqualFold(method, "AES-128") || strings.EqualFold(method, "SAMPLE-AES") {
				encrypted, keyActive = true, true
			} else {
				keyActive = false // METHOD=NONE
			}
			kept = append(kept, line)
			continue
		}
		if strings.HasPrefix(text, "#EXTINF:") {
			inSegments = true
			pendingExtInf = len(kept)
			kept = append(kept, line)
			continue
		}
		if strings.HasPrefix(text, "#") {
			kept = append(kept, line)
			continue
		}

		// 分段地址行：解析时长并判断是否广告。
		dur := 0.0
		if pendingExtInf >= 0 && pendingExtInf < len(kept) {
			dur = extInfDuration(strings.TrimSpace(kept[pendingExtInf]))
		}
		seg := adSegment{uri: text, duration: dur}
		plain := encrypted && !keyActive
		if inSegments && isAd(seg, prevURI, plain) {
			if pendingExtInf >= 0 && pendingExtInf < len(kept) {
				kept = append(kept[:pendingExtInf], kept[pendingExtInf+1:]...)
			}
			dropped++
			pendingExtInf = -1
			continue
		}
		prevURI = text
		keptSegments++
		pendingExtInf = -1
		kept = append(kept, line)
	}

	// 保护正片：无广告、无剩余分段、或过滤比例过高都不改。
	if dropped == 0 || keptSegments == 0 ||
		float64(dropped)/float64(dropped+keptSegments) > 0.4 {
		return body
	}
	return strings.Join(kept, "\n")
}

func extInfDuration(line string) float64 {
	raw := strings.TrimPrefix(line, "#EXTINF:")
	if comma := strings.IndexByte(raw, ','); comma >= 0 {
		raw = raw[:comma]
	}
	value, _ := strconv.ParseFloat(strings.TrimSpace(raw), 64)
	return value
}

// playlistAttr 读取 #EXT-X-*: 标签中 KEY=VALUE 的属性值。
func playlistAttr(line, key string) string {
	idx := strings.IndexByte(line, ':')
	if idx < 0 {
		return ""
	}
	for _, part := range strings.Split(line[idx+1:], ",") {
		kv := strings.SplitN(strings.TrimSpace(part), "=", 2)
		if len(kv) == 2 && kv[0] == key {
			return strings.Trim(strings.TrimSpace(kv[1]), `"`)
		}
	}
	return ""
}
