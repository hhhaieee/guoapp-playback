package core

import (
	"strings"
	"testing"
)

func TestStripAdsFromPlaylist(t *testing.T) {
	const base = "https://media.example.com/hls/index.m3u8"
	body := strings.Join([]string{
		"#EXTM3U",
		"#EXT-X-VERSION:3",
		"#EXT-X-TARGETDURATION:10",
		"#EXTINF:10.0,",
		"seg1.ts",
		"#EXTINF:5.0,",
		"https://ads.other.com/adjump/promo.ts", // 异域名 + adjump 广告
		"#EXTINF:10.0,",
		"seg2.ts",
		"#EXTINF:4.0,",
		"dup.ts",
		"#EXTINF:4.0,",
		"dup.ts", // 重复短段
		"#EXT-X-ENDLIST",
	}, "\n")

	got := stripAdsFromPlaylist(body, base)
	for _, want := range []string{"#EXTM3U", "#EXT-X-VERSION:3", "#EXT-X-TARGETDURATION:10", "seg1.ts", "seg2.ts", "#EXT-X-ENDLIST"} {
		if !strings.Contains(got, want) {
			t.Errorf("过滤结果缺少应保留内容 %q:\n%s", want, got)
		}
	}
	for _, unwanted := range []string{"adjump", "promo.ts"} {
		if strings.Contains(got, unwanted) {
			t.Errorf("过滤结果仍包含广告 %q:\n%s", unwanted, got)
		}
	}
	// 连续重复短段：保留第一份，去掉重复的一份。
	if count := strings.Count(got, "dup.ts"); count != 1 {
		t.Errorf("重复短段应只保留一份，实际 %d 份:\n%s", count, got)
	}
}

func TestStripAdsKeepsAllWhenNoAd(t *testing.T) {
	const base = "https://media.example.com/hls/index.m3u8"
	body := strings.Join([]string{
		"#EXTM3U",
		"#EXT-X-VERSION:3",
		"#EXTINF:10.0,",
		"seg1.ts",
		"#EXTINF:10.0,",
		"seg2.ts",
		"#EXTINF:10.0,",
		"seg3.ts",
		"#EXT-X-ENDLIST",
	}, "\n")
	if got := stripAdsFromPlaylist(body, base); got != body {
		t.Errorf("无广告时不应改动列表:\n%s", got)
	}
}

func TestStripAdsPlaintextShortInAES(t *testing.T) {
	const base = "https://media.example.com/hls/index.m3u8"
	body := strings.Join([]string{
		"#EXTM3U",
		"#EXT-X-KEY:METHOD=AES-128,URI=\"key.bin\"",
		"#EXTINF:10.0,",
		"enc1.ts",
		"#EXT-X-KEY:METHOD=NONE",
		"#EXTINF:3.0,",
		"plain_ad.ts", // AES 源中明文短段
		"#EXT-X-KEY:METHOD=AES-128,URI=\"key.bin\"",
		"#EXTINF:10.0,",
		"enc2.ts",
		"#EXT-X-ENDLIST",
	}, "\n")
	got := stripAdsFromPlaylist(body, base)
	if strings.Contains(got, "plain_ad.ts") {
		t.Errorf("未过滤 AES 源中的明文短段:\n%s", got)
	}
	if !strings.Contains(got, "enc1.ts") || !strings.Contains(got, "enc2.ts") {
		t.Errorf("误删加密正片分段:\n%s", got)
	}
	if !strings.Contains(got, "METHOD=AES-128") {
		t.Errorf("误删 KEY 结构标签:\n%s", got)
	}
}

func TestStripAdsSafetyThreshold(t *testing.T) {
	const base = "https://media.example.com/hls/index.m3u8"
	// 10 段中 8 段是广告（>40%），应放弃过滤保护正片。
	var lines []string
	lines = append(lines, "#EXTM3U")
	for i := 0; i < 8; i++ {
		lines = append(lines, "#EXTINF:3.0,", "https://ads.other.com/adjump/a.ts")
	}
	for i := 0; i < 2; i++ {
		lines = append(lines, "#EXTINF:10.0,", "real.ts")
	}
	lines = append(lines, "#EXT-X-ENDLIST")
	body := strings.Join(lines, "\n")
	if got := stripAdsFromPlaylist(body, base); got != body {
		t.Errorf("过滤比例过高时应放弃过滤:\n%s", got)
	}
}
