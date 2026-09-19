import 'dart:convert';

/// Mirrors DS.DEFAULT_SETTINGS from the Chrome extension's core.js
class AppSettings {
  bool enabled;

  // NSFW
  String globalNsfwMode;

  // Tags
  bool autoTags;
  List<String> includeTags;
  List<String> excludeTags;

  // Premium
  bool hidePremium;
  bool hideFloatingPremiumPopups;
  bool hideNotifications;
  bool autoReadNotifications;

  // Card blocking
  bool blockCards;
  List<String> blockedTags;
  List<String> blockedWords;
  List<String> blockedCreators;
  List<String> blockedBotIds;
  List<String> blockedBotNames;
  bool neverHideFavorites;
  bool protectFavoritesFromBlocking;
  bool hideGroupChats;

  // Opened chats
  bool trackOpenedChats;
  bool importOpenedFromChatsPage;
  bool hideOpenedChats;

  // Hidden card display
  String hiddenCardMode;
  bool compactAfterHiding;

  // Quick panel
  bool showQuickPanel;
  String quickPanelMode;
  bool showBlockCurrentBotButton;
  bool replaceCardProfileWithBlockButton;

  // Chat list
  bool showChatListTools;
  String chatListSortMode;
  String chatListSearchMode;
  bool autoLoadAllOpenedChats;
  int deepImportMaxPages;

  // Chat tools
  bool showChatExportButton;
  bool showOocTools;

  // Personas
  bool autoAcceptPersonaChange;
  bool savePersonasFromPages;
  bool showPersonaQuickSwitch;
  int personaQuickSwitchLimit;
  bool skipPersonaPickerOnNewChat;
  String lastUsedPersonaId;

  // Chat UI cleanup
  bool hideChatPlusButton;
  bool hideChatImageButton;
  bool hideChatVoiceButton;
  bool hideUnlockCustomVoices;

  // Sidebar
  bool hideSidebarLogo;
  bool hideSidebarHome;
  bool hideSidebarChats;
  bool hideSidebarPersonas;
  bool hideSidebarCreateMenu;
  bool hideSidebarCreateChatbot;
  bool hideSidebarCreateLorebook;
  bool hideSidebarCreateGroup;
  bool hideSidebarCreateVoice;
  bool hideSidebarMyCreationsMenu;
  bool hideSidebarMyChatbots;
  bool hideSidebarMyLorebooks;
  bool hideSidebarMyGroups;
  bool hideSidebarMyVoices;
  bool hideSidebarFavorites;
  bool hideSidebarRecommendations;
  bool hideSidebarLeaderboard;
  bool hideSidebarBlockedCreators;
  bool hideSidebarSubscribe;
  bool hideSidebarHelp;
  bool hideSidebarSocialLinks;
  bool hideSidebarFooterLinks;
  bool hideSidebarAppDownload;
  bool hideSidebarWebVersion;
  bool hideSidebarSignOut;

  // Settings added by newer extension builds that are not yet shown in the native UI.
  // Keeping them here prevents the native settings screen from deleting them.
  Map<String, dynamic> extra;

  // Debug
  bool debug;

  AppSettings({
    this.enabled = true,
    this.globalNsfwMode = 'ignore',
    this.autoTags = false,
    this.includeTags = const [],
    this.excludeTags = const [],
    this.hidePremium = true,
    this.hideFloatingPremiumPopups = true,
    this.hideNotifications = false,
    this.autoReadNotifications = false,
    this.blockCards = true,
    this.blockedTags = const [],
    this.blockedWords = const [],
    this.blockedCreators = const [],
    this.blockedBotIds = const [],
    this.blockedBotNames = const [],
    this.neverHideFavorites = true,
    this.protectFavoritesFromBlocking = true,
    this.hideGroupChats = false,
    this.trackOpenedChats = true,
    this.importOpenedFromChatsPage = true,
    this.hideOpenedChats = true,
    this.hiddenCardMode = 'hide',
    this.compactAfterHiding = true,
    this.showQuickPanel = true,
    this.quickPanelMode = 'compact',
    this.showBlockCurrentBotButton = false,
    this.replaceCardProfileWithBlockButton = true,
    this.showChatListTools = true,
    this.chatListSortMode = 'default',
    this.chatListSearchMode = 'all',
    this.autoLoadAllOpenedChats = false,
    this.deepImportMaxPages = 80,
    this.showChatExportButton = true,
    this.showOocTools = true,
    this.autoAcceptPersonaChange = false,
    this.savePersonasFromPages = true,
    this.showPersonaQuickSwitch = true,
    this.personaQuickSwitchLimit = 6,
    this.skipPersonaPickerOnNewChat = false,
    this.lastUsedPersonaId = '',
    this.hideChatPlusButton = false,
    this.hideChatImageButton = false,
    this.hideChatVoiceButton = false,
    this.hideUnlockCustomVoices = false,
    this.hideSidebarLogo = false,
    this.hideSidebarHome = false,
    this.hideSidebarChats = false,
    this.hideSidebarPersonas = false,
    this.hideSidebarCreateMenu = false,
    this.hideSidebarCreateChatbot = false,
    this.hideSidebarCreateLorebook = false,
    this.hideSidebarCreateGroup = false,
    this.hideSidebarCreateVoice = false,
    this.hideSidebarMyCreationsMenu = false,
    this.hideSidebarMyChatbots = false,
    this.hideSidebarMyLorebooks = false,
    this.hideSidebarMyGroups = false,
    this.hideSidebarMyVoices = false,
    this.hideSidebarFavorites = false,
    this.hideSidebarRecommendations = false,
    this.hideSidebarLeaderboard = false,
    this.hideSidebarBlockedCreators = false,
    this.hideSidebarSubscribe = false,
    this.hideSidebarHelp = false,
    this.hideSidebarSocialLinks = false,
    this.hideSidebarFooterLinks = false,
    this.hideSidebarAppDownload = false,
    this.hideSidebarWebVersion = false,
    this.hideSidebarSignOut = false,
    this.extra = const {},
    this.debug = false,
  });

  Map<String, dynamic> toJson() => {
        ...extra,
        'enabled': enabled,
        'globalNsfwMode': globalNsfwMode,
        'autoTags': autoTags,
        'includeTags': includeTags,
        'excludeTags': excludeTags,
        'hidePremium': hidePremium,
        'hideFloatingPremiumPopups': hideFloatingPremiumPopups,
        'hideNotifications': hideNotifications,
        'autoReadNotifications': autoReadNotifications,
        'blockCards': blockCards,
        'blockedTags': blockedTags,
        'blockedWords': blockedWords,
        'blockedCreators': blockedCreators,
        'blockedBotIds': blockedBotIds,
        'blockedBotNames': blockedBotNames,
        'neverHideFavorites': neverHideFavorites,
        'protectFavoritesFromBlocking': protectFavoritesFromBlocking,
        'hideGroupChats': hideGroupChats,
        'trackOpenedChats': trackOpenedChats,
        'importOpenedFromChatsPage': importOpenedFromChatsPage,
        'hideOpenedChats': hideOpenedChats,
        'hiddenCardMode': hiddenCardMode,
        'compactAfterHiding': compactAfterHiding,
        'showQuickPanel': showQuickPanel,
        'quickPanelMode': quickPanelMode,
        'showBlockCurrentBotButton': showBlockCurrentBotButton,
        'replaceCardProfileWithBlockButton': replaceCardProfileWithBlockButton,
        'showChatListTools': showChatListTools,
        'chatListSortMode': chatListSortMode,
        'chatListSearchMode': chatListSearchMode,
        'autoLoadAllOpenedChats': autoLoadAllOpenedChats,
        'deepImportMaxPages': deepImportMaxPages,
        'showChatExportButton': showChatExportButton,
        'showOocTools': showOocTools,
        'autoAcceptPersonaChange': autoAcceptPersonaChange,
        'savePersonasFromPages': savePersonasFromPages,
        'showPersonaQuickSwitch': showPersonaQuickSwitch,
        'personaQuickSwitchLimit': personaQuickSwitchLimit,
        'skipPersonaPickerOnNewChat': skipPersonaPickerOnNewChat,
        'lastUsedPersonaId': lastUsedPersonaId,
        'hideChatPlusButton': hideChatPlusButton,
        'hideChatImageButton': hideChatImageButton,
        'hideChatVoiceButton': hideChatVoiceButton,
        'hideUnlockCustomVoices': hideUnlockCustomVoices,
        'hideSidebarLogo': hideSidebarLogo,
        'hideSidebarHome': hideSidebarHome,
        'hideSidebarChats': hideSidebarChats,
        'hideSidebarPersonas': hideSidebarPersonas,
        'hideSidebarCreateMenu': hideSidebarCreateMenu,
        'hideSidebarCreateChatbot': hideSidebarCreateChatbot,
        'hideSidebarCreateLorebook': hideSidebarCreateLorebook,
        'hideSidebarCreateGroup': hideSidebarCreateGroup,
        'hideSidebarCreateVoice': hideSidebarCreateVoice,
        'hideSidebarMyCreationsMenu': hideSidebarMyCreationsMenu,
        'hideSidebarMyChatbots': hideSidebarMyChatbots,
        'hideSidebarMyLorebooks': hideSidebarMyLorebooks,
        'hideSidebarMyGroups': hideSidebarMyGroups,
        'hideSidebarMyVoices': hideSidebarMyVoices,
        'hideSidebarFavorites': hideSidebarFavorites,
        'hideSidebarRecommendations': hideSidebarRecommendations,
        'hideSidebarLeaderboard': hideSidebarLeaderboard,
        'hideSidebarBlockedCreators': hideSidebarBlockedCreators,
        'hideSidebarSubscribe': hideSidebarSubscribe,
        'hideSidebarHelp': hideSidebarHelp,
        'hideSidebarSocialLinks': hideSidebarSocialLinks,
        'hideSidebarFooterLinks': hideSidebarFooterLinks,
        'hideSidebarAppDownload': hideSidebarAppDownload,
        'hideSidebarWebVersion': hideSidebarWebVersion,
        'hideSidebarSignOut': hideSidebarSignOut,
        'debug': debug,
      };

  factory AppSettings.fromJson(Map<String, dynamic> json) {
    return AppSettings(
      enabled: json['enabled'] ?? true,
      globalNsfwMode: json['globalNsfwMode'] ?? 'ignore',
      autoTags: json['autoTags'] ?? false,
      includeTags: List<String>.from(json['includeTags'] ?? []),
      excludeTags: List<String>.from(json['excludeTags'] ?? []),
      hidePremium: json['hidePremium'] ?? true,
      hideFloatingPremiumPopups: json['hideFloatingPremiumPopups'] ?? true,
      hideNotifications: json['hideNotifications'] ?? false,
      autoReadNotifications: json['autoReadNotifications'] ?? false,
      blockCards: json['blockCards'] ?? true,
      blockedTags: List<String>.from(json['blockedTags'] ?? []),
      blockedWords: List<String>.from(json['blockedWords'] ?? []),
      blockedCreators: List<String>.from(json['blockedCreators'] ?? []),
      blockedBotIds: List<String>.from(json['blockedBotIds'] ?? []),
      blockedBotNames: List<String>.from(json['blockedBotNames'] ?? []),
      neverHideFavorites: json['neverHideFavorites'] ?? true,
      protectFavoritesFromBlocking:
          json['protectFavoritesFromBlocking'] ?? true,
      hideGroupChats: json['hideGroupChats'] ?? false,
      trackOpenedChats: json['trackOpenedChats'] ?? true,
      importOpenedFromChatsPage: json['importOpenedFromChatsPage'] ?? true,
      hideOpenedChats: json['hideOpenedChats'] ?? true,
      hiddenCardMode: json['hiddenCardMode'] ?? 'hide',
      compactAfterHiding: json['compactAfterHiding'] ?? true,
      showQuickPanel: json['showQuickPanel'] ?? true,
      quickPanelMode: json['quickPanelMode'] ?? 'compact',
      showBlockCurrentBotButton: json['showBlockCurrentBotButton'] ?? false,
      replaceCardProfileWithBlockButton:
          json['replaceCardProfileWithBlockButton'] ?? true,
      showChatListTools: json['showChatListTools'] ?? true,
      chatListSortMode: json['chatListSortMode'] ?? 'default',
      chatListSearchMode: json['chatListSearchMode'] ?? 'all',
      autoLoadAllOpenedChats: json['autoLoadAllOpenedChats'] ?? false,
      deepImportMaxPages: json['deepImportMaxPages'] ?? 80,
      showChatExportButton: json['showChatExportButton'] ?? true,
      showOocTools: json['showOocTools'] ?? true,
      autoAcceptPersonaChange: json['autoAcceptPersonaChange'] ?? false,
      savePersonasFromPages: json['savePersonasFromPages'] ?? true,
      showPersonaQuickSwitch: json['showPersonaQuickSwitch'] ?? true,
      personaQuickSwitchLimit: json['personaQuickSwitchLimit'] ?? 6,
      skipPersonaPickerOnNewChat: json['skipPersonaPickerOnNewChat'] ?? false,
      lastUsedPersonaId: json['lastUsedPersonaId'] ?? '',
      hideChatPlusButton: json['hideChatPlusButton'] ?? false,
      hideChatImageButton: json['hideChatImageButton'] ?? false,
      hideChatVoiceButton: json['hideChatVoiceButton'] ?? false,
      hideUnlockCustomVoices: json['hideUnlockCustomVoices'] ?? false,
      hideSidebarLogo: json['hideSidebarLogo'] ?? false,
      hideSidebarHome: json['hideSidebarHome'] ?? false,
      hideSidebarChats: json['hideSidebarChats'] ?? false,
      hideSidebarPersonas: json['hideSidebarPersonas'] ?? false,
      hideSidebarCreateMenu: json['hideSidebarCreateMenu'] ?? false,
      hideSidebarCreateChatbot: json['hideSidebarCreateChatbot'] ?? false,
      hideSidebarCreateLorebook: json['hideSidebarCreateLorebook'] ?? false,
      hideSidebarCreateGroup: json['hideSidebarCreateGroup'] ?? false,
      hideSidebarCreateVoice: json['hideSidebarCreateVoice'] ?? false,
      hideSidebarMyCreationsMenu: json['hideSidebarMyCreationsMenu'] ?? false,
      hideSidebarMyChatbots: json['hideSidebarMyChatbots'] ?? false,
      hideSidebarMyLorebooks: json['hideSidebarMyLorebooks'] ?? false,
      hideSidebarMyGroups: json['hideSidebarMyGroups'] ?? false,
      hideSidebarMyVoices: json['hideSidebarMyVoices'] ?? false,
      hideSidebarFavorites: json['hideSidebarFavorites'] ?? false,
      hideSidebarRecommendations: json['hideSidebarRecommendations'] ?? false,
      hideSidebarLeaderboard: json['hideSidebarLeaderboard'] ?? false,
      hideSidebarBlockedCreators: json['hideSidebarBlockedCreators'] ?? false,
      hideSidebarSubscribe: json['hideSidebarSubscribe'] ?? false,
      hideSidebarHelp: json['hideSidebarHelp'] ?? false,
      hideSidebarSocialLinks: json['hideSidebarSocialLinks'] ?? false,
      hideSidebarFooterLinks: json['hideSidebarFooterLinks'] ?? false,
      hideSidebarAppDownload: json['hideSidebarAppDownload'] ?? false,
      hideSidebarWebVersion: json['hideSidebarWebVersion'] ?? false,
      hideSidebarSignOut: json['hideSidebarSignOut'] ?? false,
      extra: Map<String, dynamic>.from(json),
      debug: json['debug'] ?? false,
    );
  }

  String toJsonString() => jsonEncode(toJson());

  factory AppSettings.fromJsonString(String jsonStr) {
    try {
      return AppSettings.fromJson(jsonDecode(jsonStr));
    } catch (_) {
      return AppSettings();
    }
  }
}
