import 'dart:math' as math;
import 'dart:ui' show Size;

import 'catalog_sort.dart';

const playbackSpeeds = [.5, .75, 1.0, 1.1, 1.25, 1.5, 2.0, 3.0];
const boostSpeeds = [1.5, 2.0, 2.5, 3.0, 4.0];
const danmakuColors = [
  0xFFFFFFFF,
  0xFFFFE066,
  0xFF66E0FF,
  0xFFFF8FB8,
  0xFF8CF08C,
];

enum TelevisionDecoder { optimized, hardware, software, hardwareSwapUv }

enum DanmakuCoverage {
  quarter(.25, '1/4屏'),
  third(.34, '1/3屏'),
  half(.5, '1/2屏'),
  most(.75, '3/4屏');

  const DanmakuCoverage(this.fraction, this.label);

  final double fraction;
  final String label;
}

/// 弹幕字号四档（相对默认 16pt 的比例）。字号越大行数越少，由渲染层按行高自动计算。
const danmakuScaleSteps = [0.8, 1.0, 1.25, 1.5];

/// 弹幕不透明度四档。
const danmakuOpacitySteps = [0.4, 0.6, 0.8, 1.0];

/// 弹幕滚动速度三档：慢/中/快，分别约 11/8.5/6.5 秒穿过屏幕。
/// 渲染层 lifetime = danmakuLifetimeMs(8000) / speed。
const danmakuSpeedSteps = [0.73, 0.94, 1.23];
const danmakuSpeedLabels = ['慢', '中', '快'];

enum DanmakuMerge {
  off(0, '关闭'),
  ten(10, '10 秒'),
  twenty(20, '20 秒'),
  thirty(30, '30 秒');

  const DanmakuMerge(this.seconds, this.label);

  final int seconds;
  final String label;
}

/// 长视频缓存预缓冲容量档位（MB）。0 表示关闭。
/// 短剧仍按预加载后续 3-4 集处理，与该档位无关。
enum PrebufferSize {
  off(0, '关闭'),
  mb200(200, '200 MB'),
  mb500(500, '500 MB'),
  mb750(750, '750 MB'),
  mb1000(1000, '1000 MB');

  const PrebufferSize(this.megabytes, this.label);

  final int megabytes;
  final String label;

  int get bytes => megabytes * 1024 * 1024;
}

enum VideoFit {
  auto('自动'),
  stretch('拉伸'),
  crop('裁切'),
  fitWidth('等宽'),
  fitHeight('等高'),
  original('原始'),
  ratio4x3('4:3'),
  ratio16x9('16:9');

  const VideoFit(this.label);

  final String label;

  Size size(Size box, Size video, double pixelRatio) {
    final aspect = video.width / video.height;
    double long(double ratio) => aspect < 1 ? 1 / ratio : ratio;
    Size fit(double aspect, double Function(double, double) pick) {
      final height = pick(box.height, box.width / aspect);
      return Size(height * aspect, height);
    }

    return switch (this) {
      auto => fit(aspect, math.min),
      stretch => box,
      crop => fit(aspect, math.max),
      fitWidth => Size(box.width, box.width / aspect),
      fitHeight => Size(box.height * aspect, box.height),
      original => video / pixelRatio,
      ratio4x3 => fit(long(4 / 3), math.min),
      ratio16x9 => fit(long(16 / 9), math.min),
    };
  }
}

const danmakuScaleMin = .6;
const danmakuScaleMax = 2.0;

const danmakuStrokeMin = 0.0;
const danmakuStrokeMax = 6.0;

const danmakuShadowMin = 0.0;
const danmakuShadowMax = 12.0;

const danmakuSpeedMin = .5;
const danmakuSpeedMax = 2.0;

const danmakuWordLength = 40;
const danmakuWordLimit = 60;

class PlaybackPreferences {
  const PlaybackPreferences({
    this.speed = 1,
    this.boostSpeed = 2,
    this.quality = 0,
    this.autoAdvance = true,
    this.danmaku = true,
    this.danmakuScale = 1,
    this.danmakuColor = 0xFFFFFFFF,
    this.danmakuOpacity = 0.8,
    this.danmakuBold = true,
    this.danmakuStroke = 0,
    this.danmakuShadow = 3,
    this.danmakuCoverage = DanmakuCoverage.third,
    this.danmakuSpeed = 0.94,
    this.danmakuMerge = DanmakuMerge.ten,
    this.danmakuWords = const [],
    this.preload = true,
    this.televisionDecoder = TelevisionDecoder.optimized,
    this.preopen,
    this.doubleTapSeek = true,
    this.swipeLevels = true,
    this.swipeEpisodes = true,
    this.progressLine = true,
    this.showClock = true,
    this.showNetworkSpeed = true,
    this.autoHideControls = true,
    this.hideSystemBars = true,
    this.portraitStyleForWide = false,
    this.directPlay = false,
    this.autoPictureInPicture = false,
    this.backgroundPlayback = false,
    this.videoFit = VideoFit.auto,
    this.prebufferSize = PrebufferSize.off,
    this.volumeKeysHud = true,
    this.removeAds = true,
  });

  final double speed;
  final int quality;
  final bool autoAdvance;
  final bool danmaku;
  final double danmakuScale;
  final int danmakuColor;
  final double danmakuOpacity;
  final bool danmakuBold;
  final double danmakuStroke;
  final double danmakuShadow;
  final DanmakuCoverage danmakuCoverage;
  final double danmakuSpeed;
  final DanmakuMerge danmakuMerge;
  final double boostSpeed;

  String get boostLabel =>
      '${boostSpeed % 1 == 0 ? boostSpeed.toInt() : boostSpeed} 倍速';
  final List<String> danmakuWords;
  final bool preload;
  final TelevisionDecoder televisionDecoder;
  final bool? preopen;
  final bool doubleTapSeek;
  final bool swipeLevels;
  final bool swipeEpisodes;
  final bool progressLine;
  final bool showClock;
  final bool showNetworkSpeed;
  final bool autoHideControls;
  final bool hideSystemBars;
  final bool portraitStyleForWide;
  final bool directPlay;
  final bool autoPictureInPicture;
  final bool backgroundPlayback;
  final VideoFit videoFit;
  final PrebufferSize prebufferSize;
  final bool volumeKeysHud;
  final bool removeAds;

  bool preopens({required bool television}) => preopen ?? !television;

  PlaybackPreferences copyWith({
    double? speed,
    int? quality,
    bool? autoAdvance,
    bool? danmaku,
    double? danmakuScale,
    int? danmakuColor,
    double? danmakuOpacity,
    bool? danmakuBold,
    double? danmakuStroke,
    double? danmakuShadow,
    DanmakuCoverage? danmakuCoverage,
    double? danmakuSpeed,
    DanmakuMerge? danmakuMerge,
    double? boostSpeed,
    List<String>? danmakuWords,
    bool? preload,
    TelevisionDecoder? televisionDecoder,
    bool? preopen,
    bool? doubleTapSeek,
    bool? swipeLevels,
    bool? swipeEpisodes,
    bool? progressLine,
    bool? showClock,
    bool? showNetworkSpeed,
    bool? autoHideControls,
    bool? hideSystemBars,
    bool? portraitStyleForWide,
    bool? directPlay,
    bool? autoPictureInPicture,
    bool? backgroundPlayback,
    VideoFit? videoFit,
    PrebufferSize? prebufferSize,
    bool? volumeKeysHud,
    bool? removeAds,
  }) => PlaybackPreferences(
    speed: speed ?? this.speed,
    quality: quality ?? this.quality,
    autoAdvance: autoAdvance ?? this.autoAdvance,
    danmaku: danmaku ?? this.danmaku,
    danmakuScale: danmakuScale ?? this.danmakuScale,
    danmakuColor: danmakuColor ?? this.danmakuColor,
    danmakuOpacity: danmakuOpacity ?? this.danmakuOpacity,
    danmakuBold: danmakuBold ?? this.danmakuBold,
    danmakuStroke: danmakuStroke ?? this.danmakuStroke,
    danmakuShadow: danmakuShadow ?? this.danmakuShadow,
    danmakuCoverage: danmakuCoverage ?? this.danmakuCoverage,
    danmakuSpeed: danmakuSpeed ?? this.danmakuSpeed,
    danmakuMerge: danmakuMerge ?? this.danmakuMerge,
    boostSpeed: boostSpeed ?? this.boostSpeed,
    danmakuWords: danmakuWords ?? this.danmakuWords,
    preload: preload ?? this.preload,
    televisionDecoder: televisionDecoder ?? this.televisionDecoder,
    preopen: preopen ?? this.preopen,
    doubleTapSeek: doubleTapSeek ?? this.doubleTapSeek,
    swipeLevels: swipeLevels ?? this.swipeLevels,
    swipeEpisodes: swipeEpisodes ?? this.swipeEpisodes,
    progressLine: progressLine ?? this.progressLine,
    showClock: showClock ?? this.showClock,
    showNetworkSpeed: showNetworkSpeed ?? this.showNetworkSpeed,
    autoHideControls: autoHideControls ?? this.autoHideControls,
    hideSystemBars: hideSystemBars ?? this.hideSystemBars,
    portraitStyleForWide: portraitStyleForWide ?? this.portraitStyleForWide,
    directPlay: directPlay ?? this.directPlay,
    autoPictureInPicture: autoPictureInPicture ?? this.autoPictureInPicture,
    backgroundPlayback: backgroundPlayback ?? this.backgroundPlayback,
    videoFit: videoFit ?? this.videoFit,
    prebufferSize: prebufferSize ?? this.prebufferSize,
    volumeKeysHud: volumeKeysHud ?? this.volumeKeysHud,
    removeAds: removeAds ?? this.removeAds,
  );

  Map<String, dynamic> toJson() => {
    'speed': speed,
    'quality': quality,
    'autoAdvance': autoAdvance,
    'danmaku': danmaku,
    'danmakuScale': danmakuScale,
    'danmakuColor': danmakuColor,
    'danmakuOpacity': danmakuOpacity,
    'danmakuBold': danmakuBold,
    'danmakuStroke': danmakuStroke,
    'danmakuShadow': danmakuShadow,
    'danmakuCoverage': danmakuCoverage.name,
    'danmakuSpeed': danmakuSpeed,
    'danmakuMerge': danmakuMerge.name,
    'boostSpeed': boostSpeed,
    'danmakuWords': danmakuWords,
    'preload': preload,
    'televisionDecoder': televisionDecoder.name,
    if (preopen != null) 'preopen': preopen,
    'doubleTapSeek': doubleTapSeek,
    'swipeLevels': swipeLevels,
    'swipeEpisodes': swipeEpisodes,
    'progressLine': progressLine,
    'showClock': showClock,
    'showNetworkSpeed': showNetworkSpeed,
    'autoHideControls': autoHideControls,
    'hideSystemBars': hideSystemBars,
    'portraitStyleForWide': portraitStyleForWide,
    'directPlay': directPlay,
    'autoPictureInPicture': autoPictureInPicture,
    'backgroundPlayback': backgroundPlayback,
    'videoFit': videoFit.name,
    'prebufferSize': prebufferSize.name,
    'volumeKeysHud': volumeKeysHud,
    'removeAds': removeAds,
  };

  factory PlaybackPreferences.fromJson(Map<String, dynamic> value) {
    final speed = (value['speed'] as num? ?? 1).toDouble();
    final quality = value['quality'] as int? ?? 0;
    final boostSpeed = (value['boostSpeed'] as num? ?? 2).toDouble();
    final autoAdvance = value['autoAdvance'] as bool? ?? true;
    final danmaku = value['danmaku'] as bool? ?? true;
    final preload = value['preload'] as bool? ?? true;
    final danmakuScale = (value['danmakuScale'] as num? ?? 1).toDouble();
    final danmakuColor = value['danmakuColor'] as int? ?? 0xFFFFFFFF;
    if (!playbackSpeeds.contains(speed) || quality < 0 || quality > 4320) {
      throw const FormatException('播放偏好无效');
    }
    return PlaybackPreferences(
      speed: speed,
      boostSpeed: boostSpeeds.contains(boostSpeed) ? boostSpeed : 2,
      quality: quality,
      autoAdvance: autoAdvance,
      danmaku: danmaku,
      danmakuScale: danmakuScale.clamp(danmakuScaleMin, danmakuScaleMax),
      danmakuColor: danmakuColors.contains(danmakuColor)
          ? danmakuColor
          : 0xFFFFFFFF,
      danmakuOpacity: (value['danmakuOpacity'] as num? ?? 0.8).toDouble().clamp(
        0.4,
        1.0,
      ),
      danmakuBold: value['danmakuBold'] as bool? ?? true,
      danmakuStroke: (value['danmakuStroke'] as num? ?? 0).toDouble().clamp(
        danmakuStrokeMin,
        danmakuStrokeMax,
      ),
      danmakuShadow: (value['danmakuShadow'] as num? ?? 3).toDouble().clamp(
        danmakuShadowMin,
        danmakuShadowMax,
      ),
      danmakuCoverage:
          DanmakuCoverage.values.asNameMap()[value['danmakuCoverage']] ??
          DanmakuCoverage.third,
      danmakuSpeed: (value['danmakuSpeed'] as num? ?? 0.94).toDouble().clamp(
        danmakuSpeedMin,
        danmakuSpeedMax,
      ),
      danmakuMerge:
          DanmakuMerge.values.asNameMap()[value['danmakuMerge']] ??
          DanmakuMerge.ten,
      danmakuWords: normalizeDanmakuWords(value['danmakuWords']),
      preload: preload,
      televisionDecoder:
          TelevisionDecoder.values.asNameMap()[value['televisionDecoder']] ??
          TelevisionDecoder.optimized,
      preopen: value['preopen'] as bool?,
      doubleTapSeek: value['doubleTapSeek'] as bool? ?? true,
      swipeLevels: value['swipeLevels'] as bool? ?? true,
      swipeEpisodes: value['swipeEpisodes'] as bool? ?? true,
      progressLine: value['progressLine'] as bool? ?? true,
      showClock: value['showClock'] as bool? ?? true,
      showNetworkSpeed: value['showNetworkSpeed'] as bool? ?? true,
      autoHideControls: value['autoHideControls'] as bool? ?? true,
      hideSystemBars: value['hideSystemBars'] as bool? ?? true,
      portraitStyleForWide: value['portraitStyleForWide'] as bool? ?? false,
      directPlay: value['directPlay'] as bool? ?? false,
      autoPictureInPicture: value['autoPictureInPicture'] as bool? ?? false,
      backgroundPlayback: value['backgroundPlayback'] as bool? ?? false,
      videoFit: VideoFit.values.asNameMap()[value['videoFit']] ?? VideoFit.auto,
      prebufferSize:
          PrebufferSize.values.asNameMap()[value['prebufferSize']] ??
          PrebufferSize.off,
      volumeKeysHud: value['volumeKeysHud'] as bool? ?? true,
      removeAds: value['removeAds'] as bool? ?? true,
    );
  }
}

List<String> normalizeDanmakuWords(Object? value) {
  if (value is! List) return const [];
  final words = <String>[];
  final keys = <String>{};
  for (final entry in value) {
    if (entry is! String) continue;
    final word = entry.trim();
    if (word.length > danmakuWordLength) continue;
    final key = normalizedSearchText(word);
    if (key.isEmpty || !keys.add(key)) continue;
    words.add(word);
    if (words.length >= danmakuWordLimit) break;
  }
  return List.unmodifiable(words);
}
