class AndroidChatTab {
  String id;
  String title;
  String url;
  double scrollY;
  bool isHome;
  int lastUsedAtMs;

  AndroidChatTab({
    required this.id,
    required this.title,
    required this.url,
    this.scrollY = 0,
    this.isHome = false,
    int? lastUsedAtMs,
  }) : lastUsedAtMs = lastUsedAtMs ?? DateTime.now().millisecondsSinceEpoch;

  Map<String, dynamic> toJson() => {
        'id': id,
        'title': title,
        'url': url,
        'scrollY': scrollY,
        'isHome': isHome,
        'lastUsedAtMs': lastUsedAtMs,
      };

  factory AndroidChatTab.fromJson(Map<String, dynamic> json) {
    return AndroidChatTab(
      id: json['id']?.toString() ?? '',
      title: json['title']?.toString() ?? 'Chat',
      url: json['url']?.toString() ?? 'https://spicychat.ai/',
      scrollY: (json['scrollY'] as num?)?.toDouble() ?? 0,
      isHome: json['isHome'] == true,
      lastUsedAtMs: (json['lastUsedAtMs'] as num?)?.toInt(),
    );
  }
}

class AndroidTabRouteResult {
  final AndroidChatTab tab;
  final bool activeTabChanged;
  final bool created;

  const AndroidTabRouteResult({
    required this.tab,
    required this.activeTabChanged,
    required this.created,
  });
}
