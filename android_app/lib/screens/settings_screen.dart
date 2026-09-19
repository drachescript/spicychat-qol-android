import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../models/settings.dart';
import '../services/settings_service.dart';

class SettingsScreen extends StatefulWidget {
  final VoidCallback? onSettingsChanged;

  const SettingsScreen({super.key, this.onSettingsChanged});

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  late AppSettings _settings;
  bool _hasChanges = false;

  // Text controllers for list-based settings
  final _blockedTagsController = TextEditingController();
  final _blockedWordsController = TextEditingController();
  final _blockedCreatorsController = TextEditingController();
  final _includeTagsController = TextEditingController();
  final _excludeTagsController = TextEditingController();

  @override
  void initState() {
    super.initState();
    final service = Provider.of<SettingsService>(context, listen: false);
    // Make a copy so edits don't immediately affect the service
    _settings = AppSettings.fromJson(service.settings.toJson());

    _blockedTagsController.text = _settings.blockedTags.join(', ');
    _blockedWordsController.text = _settings.blockedWords.join(', ');
    _blockedCreatorsController.text = _settings.blockedCreators.join(', ');
    _includeTagsController.text = _settings.includeTags.join(', ');
    _excludeTagsController.text = _settings.excludeTags.join(', ');
  }

  @override
  void dispose() {
    _blockedTagsController.dispose();
    _blockedWordsController.dispose();
    _blockedCreatorsController.dispose();
    _includeTagsController.dispose();
    _excludeTagsController.dispose();
    super.dispose();
  }

  void _markChanged() {
    if (!_hasChanges) {
      setState(() => _hasChanges = true);
    }
  }

  Future<void> _save() async {
    // Parse comma-separated lists from text controllers
    _settings.blockedTags = _parseList(_blockedTagsController.text);
    _settings.blockedWords = _parseList(_blockedWordsController.text);
    _settings.blockedCreators = _parseList(_blockedCreatorsController.text);
    _settings.includeTags = _parseList(_includeTagsController.text);
    _settings.excludeTags = _parseList(_excludeTagsController.text);

    final service = Provider.of<SettingsService>(context, listen: false);
    await service.saveSettings(_settings);

    widget.onSettingsChanged?.call();

    setState(() => _hasChanges = false);

    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Settings saved'),
          duration: Duration(seconds: 1),
        ),
      );
    }
  }

  List<String> _parseList(String text) {
    return text
        .split(',')
        .map((s) => s.trim())
        .where((s) => s.isNotEmpty)
        .toList();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFF0F0F1A),
      appBar: AppBar(
        title: const Text('SpicyChat QOL Settings'),
        backgroundColor: const Color(0xFF1A1A2E),
        foregroundColor: Colors.white,
        elevation: 0,
        actions: [
          if (_hasChanges)
            TextButton(
              onPressed: _save,
              child: const Text(
                'SAVE',
                style: TextStyle(
                  color: Colors.deepPurpleAccent,
                  fontWeight: FontWeight.bold,
                ),
              ),
            ),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.only(bottom: 80),
        children: [
          // ── General ──
          _buildSectionHeader('General'),
          _buildSwitch(
            'Extension Enabled',
            'Master toggle for all QoL features',
            _settings.enabled,
            (v) => setState(() {
              _settings.enabled = v;
              _markChanged();
            }),
          ),
          _buildDropdown(
            'NSFW Mode',
            'Auto-set the global NSFW switch',
            _settings.globalNsfwMode,
            {'ignore': 'Ignore', 'on': 'Force ON', 'off': 'Force OFF'},
            (v) => setState(() {
              _settings.globalNsfwMode = v!;
              _markChanged();
            }),
          ),

          // ── Premium & Notifications ──
          _buildSectionHeader('Premium & Notifications'),
          _buildSwitch(
            'Hide Premium Buttons',
            'Hide subscribe/upgrade elements',
            _settings.hidePremium,
            (v) => setState(() {
              _settings.hidePremium = v;
              _markChanged();
            }),
          ),
          _buildSwitch(
            'Hide Floating Premium Popups',
            'Auto-dismiss context limit popups',
            _settings.hideFloatingPremiumPopups,
            (v) => setState(() {
              _settings.hideFloatingPremiumPopups = v;
              _markChanged();
            }),
          ),
          _buildSwitch(
            'Hide Notifications',
            'Hide the notification bell',
            _settings.hideNotifications,
            (v) => setState(() {
              _settings.hideNotifications = v;
              _markChanged();
            }),
          ),
          _buildSwitch(
            'Auto-Read Notifications',
            'Automatically open and dismiss notifications',
            _settings.autoReadNotifications,
            (v) => setState(() {
              _settings.autoReadNotifications = v;
              _markChanged();
            }),
          ),

          // ── Card Blocking ──
          _buildSectionHeader('Card Blocking'),
          _buildSwitch(
            'Block Cards',
            'Enable tag/word/creator blocking',
            _settings.blockCards,
            (v) => setState(() {
              _settings.blockCards = v;
              _markChanged();
            }),
          ),
          _buildTextList(
            'Blocked Tags',
            'Comma-separated tags to block',
            _blockedTagsController,
          ),
          _buildTextList(
            'Blocked Words',
            'Comma-separated words to block',
            _blockedWordsController,
          ),
          _buildTextList(
            'Blocked Creators',
            'Comma-separated creator names',
            _blockedCreatorsController,
          ),
          _buildSwitch(
            'Never Hide Favorites',
            'Protect favorites from all hiding',
            _settings.neverHideFavorites,
            (v) => setState(() {
              _settings.neverHideFavorites = v;
              _markChanged();
            }),
          ),
          _buildSwitch(
            'Protect Favorites From Blocking',
            'Prevent blocking bots on favorites page',
            _settings.protectFavoritesFromBlocking,
            (v) => setState(() {
              _settings.protectFavoritesFromBlocking = v;
              _markChanged();
            }),
          ),
          _buildSwitch(
            'Hide Group Chats',
            'Hide cards with multiple participants',
            _settings.hideGroupChats,
            (v) => setState(() {
              _settings.hideGroupChats = v;
              _markChanged();
            }),
          ),
          _buildDropdown(
            'Hidden Card Mode',
            'How blocked/opened cards are displayed',
            _settings.hiddenCardMode,
            {'hide': 'Hide completely', 'dim': 'Dim (show faded)'},
            (v) => setState(() {
              _settings.hiddenCardMode = v!;
              _markChanged();
            }),
          ),
          _buildSwitch(
            'Compact After Hiding',
            'Remove gaps left by hidden cards',
            _settings.compactAfterHiding,
            (v) => setState(() {
              _settings.compactAfterHiding = v;
              _markChanged();
            }),
          ),
          _buildSwitch(
            'Replace Profile Button with Block',
            'Show × block button on cards instead of info',
            _settings.replaceCardProfileWithBlockButton,
            (v) => setState(() {
              _settings.replaceCardProfileWithBlockButton = v;
              _markChanged();
            }),
          ),

          // ── Opened Chats ──
          _buildSectionHeader('Opened Chats'),
          _buildSwitch(
            'Track Opened Chats',
            'Remember which chats you\'ve visited',
            _settings.trackOpenedChats,
            (v) => setState(() {
              _settings.trackOpenedChats = v;
              _markChanged();
            }),
          ),
          _buildSwitch(
            'Import From Chat List',
            'Auto-import visible chats from /chats page',
            _settings.importOpenedFromChatsPage,
            (v) => setState(() {
              _settings.importOpenedFromChatsPage = v;
              _markChanged();
            }),
          ),
          _buildSwitch(
            'Hide Opened Chats',
            'Hide already-opened chats from recommendations',
            _settings.hideOpenedChats,
            (v) => setState(() {
              _settings.hideOpenedChats = v;
              _markChanged();
            }),
          ),

          // ── Tags ──
          _buildSectionHeader('Auto Tags'),
          _buildSwitch(
            'Auto-Apply Tags',
            'Auto include/exclude tags on page load',
            _settings.autoTags,
            (v) => setState(() {
              _settings.autoTags = v;
              _markChanged();
            }),
          ),
          _buildTextList(
            'Include Tags',
            'Comma-separated tags to auto-include',
            _includeTagsController,
          ),
          _buildTextList(
            'Exclude Tags',
            'Comma-separated tags to auto-exclude',
            _excludeTagsController,
          ),

          // ── Chat List Tools ──
          _buildSectionHeader('Chat List Tools'),
          _buildSwitch(
            'Show Chat List Tools',
            'Search, sort, load all on /chats page',
            _settings.showChatListTools,
            (v) => setState(() {
              _settings.showChatListTools = v;
              _markChanged();
            }),
          ),
          _buildDropdown(
            'Sort Mode',
            'Default chat list sort order',
            _settings.chatListSortMode,
            {
              'default': 'Last messaged',
              'messages-asc': 'Fewest messages',
              'messages-desc': 'Most messages',
              'alpha-asc': 'A–Z',
              'alpha-desc': 'Z–A',
            },
            (v) => setState(() {
              _settings.chatListSortMode = v!;
              _markChanged();
            }),
          ),

          // ── Chat UI ──
          _buildSectionHeader('Chat UI Cleanup'),
          _buildSwitch(
            'Show Chat Export Button',
            'Show export button in quick panel',
            _settings.showChatExportButton,
            (v) => setState(() {
              _settings.showChatExportButton = v;
              _markChanged();
            }),
          ),
          _buildSwitch(
            'Show OOC Tools',
            'Out-of-character message templates',
            _settings.showOocTools,
            (v) => setState(() {
              _settings.showOocTools = v;
              _markChanged();
            }),
          ),
          _buildSwitch(
            'Hide Plus Button',
            'Hide the + button in chat',
            _settings.hideChatPlusButton,
            (v) => setState(() {
              _settings.hideChatPlusButton = v;
              _markChanged();
            }),
          ),
          _buildSwitch(
            'Hide Image Button',
            'Hide the image generation button',
            _settings.hideChatImageButton,
            (v) => setState(() {
              _settings.hideChatImageButton = v;
              _markChanged();
            }),
          ),
          _buildSwitch(
            'Hide Voice Button',
            'Hide the voice/record button',
            _settings.hideChatVoiceButton,
            (v) => setState(() {
              _settings.hideChatVoiceButton = v;
              _markChanged();
            }),
          ),
          _buildSwitch(
            'Hide Unlock Custom Voices',
            'Hide the unlock custom voices button',
            _settings.hideUnlockCustomVoices,
            (v) => setState(() {
              _settings.hideUnlockCustomVoices = v;
              _markChanged();
            }),
          ),

          // ── Personas ──
          _buildSectionHeader('Personas'),
          _buildSwitch(
            'Auto-Accept Persona Change',
            'Click "Yes" on persona change confirmations',
            _settings.autoAcceptPersonaChange,
            (v) => setState(() {
              _settings.autoAcceptPersonaChange = v;
              _markChanged();
            }),
          ),
          _buildSwitch(
            'Save Personas From Pages',
            'Detect and save personas from pages',
            _settings.savePersonasFromPages,
            (v) => setState(() {
              _settings.savePersonasFromPages = v;
              _markChanged();
            }),
          ),
          _buildSwitch(
            'Show Persona Quick Switch',
            'Show numbered persona buttons in panel',
            _settings.showPersonaQuickSwitch,
            (v) => setState(() {
              _settings.showPersonaQuickSwitch = v;
              _markChanged();
            }),
          ),

          // ── Quick Panel ──
          _buildSectionHeader('Quick Panel'),
          _buildSwitch(
            'Show In-Page Quick Panel',
            'Show the floating panel inside the web page',
            _settings.showQuickPanel,
            (v) => setState(() {
              _settings.showQuickPanel = v;
              _markChanged();
            }),
          ),

          // // ── Sidebar ──
          // _buildSectionHeader('Sidebar Cleanup'),
          // ..._buildSidebarToggles(),

          // ── Debug ──
          _buildSectionHeader('Debug'),
          _buildSwitch(
            'Debug Mode',
            'Show debug badges on hidden cards',
            _settings.debug,
            (v) => setState(() {
              _settings.debug = v;
              _markChanged();
            }),
          ),
        ],
      ),
      floatingActionButton: _hasChanges
          ? FloatingActionButton.extended(
              backgroundColor: Colors.deepPurpleAccent,
              onPressed: _save,
              icon: const Icon(Icons.save, color: Colors.white),
              label: const Text('Save', style: TextStyle(color: Colors.white)),
            )
          : null,
    );
  }

  List<Widget> _buildSidebarToggles() {
    final items = <MapEntry<String, bool Function()>>[
      MapEntry('Hide Logo', () => _settings.hideSidebarLogo),
      MapEntry('Hide Home', () => _settings.hideSidebarHome),
      MapEntry('Hide Chats', () => _settings.hideSidebarChats),
      MapEntry('Hide Personas', () => _settings.hideSidebarPersonas),
      MapEntry('Hide Create Menu', () => _settings.hideSidebarCreateMenu),
      MapEntry('Hide Create Chatbot', () => _settings.hideSidebarCreateChatbot),
      MapEntry(
        'Hide Create Lorebook',
        () => _settings.hideSidebarCreateLorebook,
      ),
      MapEntry('Hide Create Group', () => _settings.hideSidebarCreateGroup),
      MapEntry('Hide Create Voice', () => _settings.hideSidebarCreateVoice),
      MapEntry(
        'Hide My Creations Menu',
        () => _settings.hideSidebarMyCreationsMenu,
      ),
      MapEntry('Hide My Chatbots', () => _settings.hideSidebarMyChatbots),
      MapEntry('Hide My Lorebooks', () => _settings.hideSidebarMyLorebooks),
      MapEntry('Hide My Groups', () => _settings.hideSidebarMyGroups),
      MapEntry('Hide My Voices', () => _settings.hideSidebarMyVoices),
      MapEntry('Hide Favorites', () => _settings.hideSidebarFavorites),
      MapEntry(
        'Hide Recommendations',
        () => _settings.hideSidebarRecommendations,
      ),
      MapEntry('Hide Leaderboard', () => _settings.hideSidebarLeaderboard),
      MapEntry(
        'Hide Blocked Creators',
        () => _settings.hideSidebarBlockedCreators,
      ),
      MapEntry('Hide Subscribe', () => _settings.hideSidebarSubscribe),
      MapEntry('Hide Help', () => _settings.hideSidebarHelp),
      MapEntry('Hide Social Links', () => _settings.hideSidebarSocialLinks),
      MapEntry('Hide Footer Links', () => _settings.hideSidebarFooterLinks),
      MapEntry('Hide App Download', () => _settings.hideSidebarAppDownload),
      MapEntry('Hide Web Version', () => _settings.hideSidebarWebVersion),
      MapEntry('Hide Sign Out', () => _settings.hideSidebarSignOut),
    ];

    return items.map((entry) {
      return _buildSwitch(
        entry.key,
        null,
        entry.value(),
        (v) => setState(() {
          _setSidebarField(entry.key, v);
          _markChanged();
        }),
      );
    }).toList();
  }

  void _setSidebarField(String label, bool value) {
    switch (label) {
      case 'Hide Logo':
        _settings.hideSidebarLogo = value;
      case 'Hide Home':
        _settings.hideSidebarHome = value;
      case 'Hide Chats':
        _settings.hideSidebarChats = value;
      case 'Hide Personas':
        _settings.hideSidebarPersonas = value;
      case 'Hide Create Menu':
        _settings.hideSidebarCreateMenu = value;
      case 'Hide Create Chatbot':
        _settings.hideSidebarCreateChatbot = value;
      case 'Hide Create Lorebook':
        _settings.hideSidebarCreateLorebook = value;
      case 'Hide Create Group':
        _settings.hideSidebarCreateGroup = value;
      case 'Hide Create Voice':
        _settings.hideSidebarCreateVoice = value;
      case 'Hide My Creations Menu':
        _settings.hideSidebarMyCreationsMenu = value;
      case 'Hide My Chatbots':
        _settings.hideSidebarMyChatbots = value;
      case 'Hide My Lorebooks':
        _settings.hideSidebarMyLorebooks = value;
      case 'Hide My Groups':
        _settings.hideSidebarMyGroups = value;
      case 'Hide My Voices':
        _settings.hideSidebarMyVoices = value;
      case 'Hide Favorites':
        _settings.hideSidebarFavorites = value;
      case 'Hide Recommendations':
        _settings.hideSidebarRecommendations = value;
      case 'Hide Leaderboard':
        _settings.hideSidebarLeaderboard = value;
      case 'Hide Blocked Creators':
        _settings.hideSidebarBlockedCreators = value;
      case 'Hide Subscribe':
        _settings.hideSidebarSubscribe = value;
      case 'Hide Help':
        _settings.hideSidebarHelp = value;
      case 'Hide Social Links':
        _settings.hideSidebarSocialLinks = value;
      case 'Hide Footer Links':
        _settings.hideSidebarFooterLinks = value;
      case 'Hide App Download':
        _settings.hideSidebarAppDownload = value;
      case 'Hide Web Version':
        _settings.hideSidebarWebVersion = value;
      case 'Hide Sign Out':
        _settings.hideSidebarSignOut = value;
    }
  }

  // ── Widget builders ──

  Widget _buildSectionHeader(String title) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 24, 16, 8),
      child: Text(
        title.toUpperCase(),
        style: TextStyle(
          color: Colors.deepPurpleAccent.withValues(alpha: 0.8),
          fontSize: 12,
          fontWeight: FontWeight.w700,
          letterSpacing: 1.2,
        ),
      ),
    );
  }

  Widget _buildSwitch(
    String title,
    String? subtitle,
    bool value,
    ValueChanged<bool> onChanged,
  ) {
    return Container(
      margin: const EdgeInsets.symmetric(horizontal: 12, vertical: 2),
      decoration: BoxDecoration(
        color: const Color(0xFF1A1A2E),
        borderRadius: BorderRadius.circular(12),
      ),
      child: SwitchListTile(
        title: Text(
          title,
          style: const TextStyle(color: Colors.white, fontSize: 14),
        ),
        subtitle: subtitle != null
            ? Text(
                subtitle,
                style: TextStyle(
                  color: Colors.white.withValues(alpha: 0.5),
                  fontSize: 12,
                ),
              )
            : null,
        value: value,
        onChanged: onChanged,
        activeTrackColor: Colors.deepPurpleAccent,
        dense: true,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      ),
    );
  }

  Widget _buildDropdown(
    String title,
    String? subtitle,
    String value,
    Map<String, String> options,
    ValueChanged<String?> onChanged,
  ) {
    return Container(
      margin: const EdgeInsets.symmetric(horizontal: 12, vertical: 2),
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      decoration: BoxDecoration(
        color: const Color(0xFF1A1A2E),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            title,
            style: const TextStyle(color: Colors.white, fontSize: 14),
          ),
          if (subtitle != null)
            Padding(
              padding: const EdgeInsets.only(top: 2),
              child: Text(
                subtitle,
                style: TextStyle(
                  color: Colors.white.withValues(alpha: 0.5),
                  fontSize: 12,
                ),
              ),
            ),
          const SizedBox(height: 8),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 12),
            decoration: BoxDecoration(
              color: const Color(0xFF111122),
              borderRadius: BorderRadius.circular(8),
              border: Border.all(color: Colors.white12),
            ),
            child: DropdownButton<String>(
              value: value,
              isExpanded: true,
              dropdownColor: const Color(0xFF1A1A2E),
              underline: const SizedBox(),
              style: const TextStyle(color: Colors.white, fontSize: 14),
              items: options.entries
                  .map(
                    (e) => DropdownMenuItem(value: e.key, child: Text(e.value)),
                  )
                  .toList(),
              onChanged: onChanged,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildTextList(
    String title,
    String hint,
    TextEditingController controller,
  ) {
    return Container(
      margin: const EdgeInsets.symmetric(horizontal: 12, vertical: 2),
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      decoration: BoxDecoration(
        color: const Color(0xFF1A1A2E),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            title,
            style: const TextStyle(color: Colors.white, fontSize: 14),
          ),
          const SizedBox(height: 8),
          TextField(
            controller: controller,
            style: const TextStyle(color: Colors.white, fontSize: 13),
            decoration: InputDecoration(
              hintText: hint,
              hintStyle: TextStyle(color: Colors.white.withValues(alpha: 0.3)),
              filled: true,
              fillColor: const Color(0xFF111122),
              border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(8),
                borderSide: const BorderSide(color: Colors.white12),
              ),
              enabledBorder: OutlineInputBorder(
                borderRadius: BorderRadius.circular(8),
                borderSide: const BorderSide(color: Colors.white12),
              ),
              focusedBorder: OutlineInputBorder(
                borderRadius: BorderRadius.circular(8),
                borderSide: const BorderSide(color: Colors.deepPurpleAccent),
              ),
              contentPadding: const EdgeInsets.symmetric(
                horizontal: 12,
                vertical: 10,
              ),
            ),
            maxLines: 2,
            onChanged: (_) => _markChanged(),
          ),
        ],
      ),
    );
  }
}
