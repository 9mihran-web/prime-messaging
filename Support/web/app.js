(function () {
  const DEFAULT_API_BASE = "https://prime-messaging-production.up.railway.app";
  const STORAGE_SESSION_KEY = "prime-web-client.session.v1";
  const STORAGE_CONFIG_KEY = "prime-web-client.config.v1";
  const STORAGE_DEVICE_ID_KEY = "prime-web-client.device-id.v1";
  const DEFAULT_REACTIONS = ["👍", "❤️", "🔥", "😂"];
  const FALLBACK_WEB_ICE_SERVERS = [
    { urls: ["stun:stun.l.google.com:19302"] },
    {
      urls: [
        "turn:openrelay.metered.ca:80?transport=udp",
        "turn:openrelay.metered.ca:443?transport=tcp",
        "turns:openrelay.metered.ca:443?transport=tcp",
      ],
      username: "openrelayproject",
      credential: "openrelayproject",
    },
  ];

  function createInitialCallState() {
    return {
      current: null,
      listPollTimer: null,
      listPolling: false,
      eventPollTimer: null,
      eventPolling: false,
      lastEventSequence: 0,
      peerConnection: null,
      localStream: null,
      remoteStream: null,
      iceServers: null,
      pendingRemoteCandidates: [],
      pendingRemoteOfferSDP: null,
      initiatedLocally: false,
      acceptedLocally: false,
      offerSent: false,
      answerSent: false,
      offerInFlight: false,
      answerInFlight: false,
      localOfferSDP: "",
      localAnswerSDP: "",
      localMuted: false,
      localVideoEnabled: false,
      localScreenShareEnabled: false,
      remoteMuted: false,
      remoteVideoEnabled: false,
      expanded: false,
      availableDevices: {
        audioinput: [],
        videoinput: [],
        audiooutput: [],
      },
      selectedAudioInputId: "",
      selectedVideoInputId: "",
      selectedAudioOutputId: "",
      requestedVideoStart: false,
      showDebugPanel: false,
      connectionLabel: "Idle",
      statusLine: "",
      debugLines: [],
      actionBusy: false,
      durationTicker: null,
      startedAtMs: 0,
    };
  }

  function normalizeSDP(value) {
    if (value == null) {
      return "";
    }
    let raw =
      typeof value === "string"
        ? value
        : typeof value?.sdp === "string"
          ? value.sdp
          : String(value);
    for (let attempt = 0; attempt < 2; attempt += 1) {
      const candidate = String(raw || "").trim();
      if (!candidate) {
        raw = "";
        break;
      }
      const looksQuoted = candidate.startsWith("\"") && candidate.endsWith("\"");
      const looksJsonObject = candidate.startsWith("{") && candidate.endsWith("}");
      if (!looksQuoted && !looksJsonObject) {
        raw = candidate;
        break;
      }
      try {
        const parsed = JSON.parse(candidate);
        if (typeof parsed === "string") {
          raw = parsed;
          continue;
        }
        if (parsed && typeof parsed.sdp === "string") {
          raw = parsed.sdp;
          continue;
        }
        raw = candidate;
        break;
      } catch (error) {
        raw = candidate;
        break;
      }
    }

    let normalized = String(raw || "").trim();
    if (!normalized) {
      return "";
    }

    if (normalized.includes("\\r\\n")) {
      normalized = normalized.replace(/\\r\\n/g, "\r\n");
    }
    if (!normalized.includes("\r\n") && normalized.includes("\\n")) {
      normalized = normalized.replace(/\\n/g, "\n");
    }
    normalized = normalized.replace(/\u0000/g, "");
    if (!normalized.includes("\r\n") && normalized.includes("\n")) {
      normalized = normalized.replace(/\r?\n/g, "\r\n");
    }
    if (normalized.startsWith("\"") && normalized.endsWith("\"")) {
      normalized = normalized.slice(1, -1);
    }
    if (!normalized.startsWith("v=") && normalized.includes("v=0")) {
      normalized = normalized.slice(normalized.indexOf("v=0"));
    }
    const cleanedLines = [];
    for (const rawLine of normalized.split(/\r\n|\n|\r/)) {
      const line = String(rawLine || "").trim();
      if (!line) {
        continue;
      }
      const unquotedLine =
        line.startsWith("\"") && line.endsWith("\"") && line.length > 1
          ? line.slice(1, -1).trim()
          : line;
      if (/^[a-z]=/i.test(unquotedLine)) {
        cleanedLines.push(unquotedLine);
        continue;
      }
      if (unquotedLine.includes("v=0")) {
        const sliced = unquotedLine.slice(unquotedLine.indexOf("v=0")).trim();
        if (/^[a-z]=/i.test(sliced)) {
          cleanedLines.push(sliced);
        }
      }
    }
    return cleanedLines.join("\r\n") + (cleanedLines.length ? "\r\n" : "");
  }

  function summarizeSDP(value) {
    const normalized = normalizeSDP(value);
    if (!normalized) {
      return "empty";
    }
    return normalized
      .split(/\r?\n/)
      .map((line) => line.trim())
      .filter(Boolean)
      .slice(0, 3)
      .join(" | ")
      .slice(0, 180);
  }

  function summarizeRawSDP(value) {
    if (value == null) {
      return "empty";
    }
    const raw =
      typeof value === "string"
        ? value
        : typeof value?.sdp === "string"
          ? value.sdp
          : String(value);
    return JSON.stringify(String(raw).slice(0, 180));
  }

  function findInvalidSDPLine(value) {
    const normalized = String(value == null ? "" : value)
      .replace(/\\r\\n/g, "\r\n")
      .replace(/\\n/g, "\n")
      .replace(/\u0000/g, "");
    const lines = normalized.split(/\r\n|\n|\r/);
    for (let index = 0; index < lines.length; index += 1) {
      const candidate = String(lines[index] || "").trim();
      if (!candidate) {
        continue;
      }
      const unquoted =
        candidate.startsWith("\"") && candidate.endsWith("\"") && candidate.length > 1
          ? candidate.slice(1, -1).trim()
          : candidate;
      if (!/^[a-z]=/i.test(unquoted)) {
        return `line${index + 1}:${JSON.stringify(unquoted.slice(0, 180))}`;
      }
    }
    return "none";
  }

  const state = {
    apiBase: DEFAULT_API_BASE,
    session: null,
    user: null,
    chats: [],
    activeChatId: null,
    messagesByChatId: new Map(),
    searchResults: [],
    devices: [],
    groupMemberSearchResults: [],
    presenceByUserId: new Map(),
    typingByChatId: new Map(),
    queuedAttachments: [],
    queuedVoiceMessage: null,
    editingMessageId: null,
    editingOriginalText: "",
    replyingToMessageId: null,
    replyingToPreview: null,
    realtime: null,
    realtimeReconnectTimer: null,
    realtimeReconnectAttempt: 0,
    realtimeIntentionalClose: false,
    lastRealtimeSeq: 0,
    searchAbortController: null,
    activeChatReadTimer: null,
    typingStopTimer: null,
    typingActive: false,
    dragDepth: 0,
    isRecordingVoice: false,
    voiceRecorder: null,
    voiceRecorderStream: null,
    voiceRecordingChunks: [],
    voiceRecordingStartedAt: 0,
    voiceRecordingTicker: null,
    voiceRecordingAnalyserTimer: null,
    voiceRecordingAudioContext: null,
    voiceRecordingDiscardNextStop: false,
    voiceWaveformSamples: [],
    bottomLockChatId: null,
    bottomLockExpiresAt: 0,
    settingsModalOpen: false,
    groupModalOpen: false,
    groupMemberSearchAbortController: null,
    groupEditor: {
      mode: "create",
      chatId: null,
      kind: "group",
      selectedMemberIds: [],
      selectedMembers: [],
      pendingAvatarFile: null,
      pendingAvatarPreviewUrl: null,
    },
    deviceId: null,
    call: createInitialCallState(),
  };

  const dom = {};

  document.addEventListener("DOMContentLoaded", init);

  function init() {
    cacheDom();
    bindEvents();
    state.deviceId = getOrCreateWebDeviceId();
    restoreConfig();
    restoreSession();
    updateApiBaseInput();
    if (state.session) {
      setAuthStatus("Restoring your session…");
      bootstrapAuthenticatedApp();
      return;
    }
    showAuthScreen();
  }

  function cacheDom() {
    dom.authScreen = document.getElementById("auth-screen");
    dom.clientScreen = document.getElementById("client-screen");
    dom.loginForm = document.getElementById("login-form");
    dom.loginIdentifier = document.getElementById("login-identifier");
    dom.loginPassword = document.getElementById("login-password");
    dom.loginSubmit = document.getElementById("login-submit");
    dom.apiBaseInput = document.getElementById("api-base-input");
    dom.authStatus = document.getElementById("auth-status");
    dom.globalSearch = document.getElementById("global-search");
    dom.searchResultsWrap = document.getElementById("search-results-wrap");
    dom.searchResults = document.getElementById("search-results");
    dom.chatList = document.getElementById("chat-list");
    dom.newGroupButton = document.getElementById("new-group-button");
    dom.newChannelButton = document.getElementById("new-channel-button");
    dom.settingsButton = document.getElementById("settings-button");
    dom.refreshButton = document.getElementById("refresh-button");
    dom.logoutButton = document.getElementById("logout-button");
    dom.connectionPill = document.getElementById("connection-pill");
    dom.meAvatar = document.getElementById("me-avatar");
    dom.meName = document.getElementById("me-name");
    dom.meHandle = document.getElementById("me-handle");
    dom.conversationEmpty = document.getElementById("conversation-empty");
    dom.conversationBody = document.getElementById("conversation-body");
    dom.chatAvatar = document.getElementById("chat-avatar");
    dom.chatTitle = document.getElementById("chat-title");
    dom.chatSubtitle = document.getElementById("chat-subtitle");
    dom.chatModePill = document.getElementById("chat-mode-pill");
    dom.callButton = document.getElementById("call-button");
    dom.videoCallButton = document.getElementById("video-call-button");
    dom.groupDetailsButton = document.getElementById("group-details-button");
    dom.markReadButton = document.getElementById("mark-read-button");
    dom.messageList = document.getElementById("message-list");
    dom.typingLine = document.getElementById("typing-line");
    dom.composerWrap = document.getElementById("composer-wrap");
    dom.replyBanner = document.getElementById("reply-banner");
    dom.replyBannerTitle = document.getElementById("reply-banner-title");
    dom.replyBannerText = document.getElementById("reply-banner-text");
    dom.cancelReplyButton = document.getElementById("cancel-reply-button");
    dom.editBanner = document.getElementById("edit-banner");
    dom.editBannerText = document.getElementById("edit-banner-text");
    dom.cancelEditButton = document.getElementById("cancel-edit-button");
    dom.voiceBanner = document.getElementById("voice-banner");
    dom.voiceBannerTitle = document.getElementById("voice-banner-title");
    dom.voiceBannerText = document.getElementById("voice-banner-text");
    dom.voicePreview = document.getElementById("voice-preview");
    dom.removeVoiceButton = document.getElementById("remove-voice-button");
    dom.attachmentStrip = document.getElementById("attachment-strip");
    dom.dropZone = document.getElementById("drop-zone");
    dom.fileInput = document.getElementById("file-input");
    dom.composerForm = document.getElementById("composer-form");
    dom.composerInput = document.getElementById("composer-input");
    dom.recordButton = document.getElementById("record-button");
    dom.sendButton = document.getElementById("send-button");
    dom.composerStatus = document.getElementById("composer-status");
    dom.settingsModal = document.getElementById("settings-modal");
    dom.settingsCloseButton = document.getElementById("settings-close-button");
    dom.settingsAvatar = document.getElementById("settings-avatar");
    dom.settingsDisplayName = document.getElementById("settings-display-name");
    dom.settingsAccountKind = document.getElementById("settings-account-kind");
    dom.settingsAvatarInput = document.getElementById("settings-avatar-input");
    dom.settingsRemoveAvatarButton = document.getElementById("settings-remove-avatar-button");
    dom.settingsAvatarStatus = document.getElementById("settings-avatar-status");
    dom.settingsProfileForm = document.getElementById("settings-profile-form");
    dom.settingsDisplayNameInput = document.getElementById("settings-display-name-input");
    dom.settingsUsernameInput = document.getElementById("settings-username-input");
    dom.settingsBioInput = document.getElementById("settings-bio-input");
    dom.settingsStatusInput = document.getElementById("settings-status-input");
    dom.settingsBirthdayInput = document.getElementById("settings-birthday-input");
    dom.settingsEmailInput = document.getElementById("settings-email-input");
    dom.settingsPhoneInput = document.getElementById("settings-phone-input");
    dom.settingsSocialLinkInput = document.getElementById("settings-social-link-input");
    dom.settingsProfileSaveButton = document.getElementById("settings-profile-save-button");
    dom.settingsProfileStatus = document.getElementById("settings-profile-status");
    dom.settingsPrivacyForm = document.getElementById("settings-privacy-form");
    dom.privacyShowEmail = document.getElementById("privacy-show-email");
    dom.privacyShowPhone = document.getElementById("privacy-show-phone");
    dom.privacyLastSeen = document.getElementById("privacy-last-seen");
    dom.privacyProfilePhoto = document.getElementById("privacy-profile-photo");
    dom.privacyCalls = document.getElementById("privacy-calls");
    dom.privacyGroupInvites = document.getElementById("privacy-group-invites");
    dom.privacyForwardLink = document.getElementById("privacy-forward-link");
    dom.privacyGuestRequests = document.getElementById("privacy-guest-requests");
    dom.settingsPrivacySaveButton = document.getElementById("settings-privacy-save-button");
    dom.settingsPrivacyStatus = document.getElementById("settings-privacy-status");
    dom.settingsPasswordForm = document.getElementById("settings-password-form");
    dom.settingsCurrentPasswordInput = document.getElementById("settings-current-password-input");
    dom.settingsNewPasswordInput = document.getElementById("settings-new-password-input");
    dom.settingsPasswordSaveButton = document.getElementById("settings-password-save-button");
    dom.settingsPasswordStatus = document.getElementById("settings-password-status");
    dom.revokeOtherSessionsButton = document.getElementById("revoke-other-sessions-button");
    dom.sessionList = document.getElementById("session-list");
    dom.settingsSessionsStatus = document.getElementById("settings-sessions-status");
    dom.groupModal = document.getElementById("group-modal");
    dom.groupCloseButton = document.getElementById("group-close-button");
    dom.groupModalTitle = document.getElementById("group-modal-title");
    dom.groupBasicsTitle = document.getElementById("group-basics-title");
    dom.groupBasicsSubtitle = document.getElementById("group-basics-subtitle");
    dom.groupAvatar = document.getElementById("group-avatar");
    dom.groupSummaryTitle = document.getElementById("group-summary-title");
    dom.groupSummarySubtitle = document.getElementById("group-summary-subtitle");
    dom.groupBasicsForm = document.getElementById("group-basics-form");
    dom.groupKindSelect = document.getElementById("group-kind-select");
    dom.groupTitleInput = document.getElementById("group-title-input");
    dom.groupPublicCheckbox = document.getElementById("group-public-checkbox");
    dom.groupCommentsCheckbox = document.getElementById("group-comments-checkbox");
    dom.groupForumCheckbox = document.getElementById("group-forum-checkbox");
    dom.groupAvatarInput = document.getElementById("group-avatar-input");
    dom.groupRemoveAvatarButton = document.getElementById("group-remove-avatar-button");
    dom.groupSaveButton = document.getElementById("group-save-button");
    dom.groupStatus = document.getElementById("group-status");
    dom.groupInviteLink = document.getElementById("group-invite-link");
    dom.copyGroupInviteButton = document.getElementById("copy-group-invite-button");
    dom.groupMemberSearchInput = document.getElementById("group-member-search-input");
    dom.groupMemberSearchResults = document.getElementById("group-member-search-results");
    dom.groupSelectedMembers = document.getElementById("group-selected-members");
    dom.groupMemberStatus = document.getElementById("group-member-status");
    dom.groupMemberList = document.getElementById("group-member-list");
    dom.groupMembersSubtitle = document.getElementById("group-members-subtitle");
    dom.groupAddPeopleSubtitle = document.getElementById("group-add-people-subtitle");
    dom.groupLeaveButton = document.getElementById("group-leave-button");
    dom.groupDeleteButton = document.getElementById("group-delete-button");
    dom.groupDangerStatus = document.getElementById("group-danger-status");
    dom.callOverlay = document.getElementById("call-overlay");
    dom.callDirectionPill = document.getElementById("call-direction-pill");
    dom.callDuration = document.getElementById("call-duration");
    dom.callDebugToggleButton = document.getElementById("call-debug-toggle-button");
    dom.callExpandButton = document.getElementById("call-expand-button");
    dom.callStage = document.getElementById("call-stage");
    dom.callStageEmpty = document.getElementById("call-stage-empty");
    dom.callRemoteVideo = document.getElementById("call-remote-video");
    dom.callLocalVideo = document.getElementById("call-local-video");
    dom.callAvatar = document.getElementById("call-avatar");
    dom.callPeerName = document.getElementById("call-peer-name");
    dom.callStatusText = document.getElementById("call-status-text");
    dom.callConnectionPill = document.getElementById("call-connection-pill");
    dom.callLocalMutedPill = document.getElementById("call-local-muted-pill");
    dom.callLocalVideoPill = document.getElementById("call-local-video-pill");
    dom.callRemoteMutedPill = document.getElementById("call-remote-muted-pill");
    dom.callRemoteVideoPill = document.getElementById("call-remote-video-pill");
    dom.callRejectButton = document.getElementById("call-reject-button");
    dom.callAnswerButton = document.getElementById("call-answer-button");
    dom.callMuteButton = document.getElementById("call-mute-button");
    dom.callVideoToggleButton = document.getElementById("call-video-toggle-button");
    dom.callScreenShareButton = document.getElementById("call-screen-share-button");
    dom.callHangupButton = document.getElementById("call-hangup-button");
    dom.callDeviceRow = document.getElementById("call-device-row");
    dom.callMicrophoneSelect = document.getElementById("call-microphone-select");
    dom.callCameraSelect = document.getElementById("call-camera-select");
    dom.callSpeakerSelect = document.getElementById("call-speaker-select");
    dom.callStatusLine = document.getElementById("call-status-line");
    dom.callDebug = document.getElementById("call-debug");
    dom.callRemoteAudio = document.getElementById("call-remote-audio");
    dom.callLocalAudio = document.getElementById("call-local-audio");
  }

  function bindEvents() {
    dom.loginForm.addEventListener("submit", onLoginSubmit);
    dom.newGroupButton.addEventListener("click", () => openGroupModalForCreate("group"));
    dom.newChannelButton.addEventListener("click", () => openGroupModalForCreate("channel"));
    dom.settingsButton.addEventListener("click", openSettingsModal);
    dom.refreshButton.addEventListener("click", onRefreshClick);
    dom.logoutButton.addEventListener("click", onLogoutClick);
    dom.globalSearch.addEventListener("input", onGlobalSearchInput);
    dom.callButton.addEventListener("click", onCallButtonClick);
    dom.videoCallButton.addEventListener("click", onVideoCallButtonClick);
    dom.groupDetailsButton.addEventListener("click", openGroupModalForActiveChat);
    dom.markReadButton.addEventListener("click", markActiveChatRead);
    dom.composerForm.addEventListener("submit", onComposerSubmit);
    dom.fileInput.addEventListener("change", onFilesSelected);
    dom.recordButton.addEventListener("click", onRecordButtonClick);
    dom.cancelReplyButton.addEventListener("click", clearReplyState);
    dom.cancelEditButton.addEventListener("click", () => clearEditingState({ resetInput: true }));
    dom.removeVoiceButton.addEventListener("click", clearQueuedVoiceMessage);
    dom.composerInput.addEventListener("input", onComposerInput);
    dom.composerInput.addEventListener("keydown", onComposerKeyDown);
    dom.messageList.addEventListener("click", onMessageListClick);
    dom.composerWrap.addEventListener("dragenter", onComposerDragEnter);
    dom.composerWrap.addEventListener("dragover", onComposerDragOver);
    dom.composerWrap.addEventListener("dragleave", onComposerDragLeave);
    dom.composerWrap.addEventListener("drop", onComposerDrop);
    dom.settingsCloseButton.addEventListener("click", closeSettingsModal);
    dom.settingsModal.addEventListener("click", onSettingsBackdropClick);
    dom.settingsAvatarInput.addEventListener("change", onSettingsAvatarSelected);
    dom.settingsRemoveAvatarButton.addEventListener("click", onRemoveAvatarClick);
    dom.settingsProfileForm.addEventListener("submit", onSettingsProfileSubmit);
    dom.settingsPrivacyForm.addEventListener("submit", onSettingsPrivacySubmit);
    dom.settingsPasswordForm.addEventListener("submit", onSettingsPasswordSubmit);
    dom.revokeOtherSessionsButton.addEventListener("click", onRevokeOtherSessionsClick);
    dom.sessionList.addEventListener("click", onSessionListClick);
    dom.groupCloseButton.addEventListener("click", closeGroupModal);
    dom.groupModal.addEventListener("click", onGroupBackdropClick);
    dom.groupBasicsForm.addEventListener("submit", onGroupBasicsSubmit);
    dom.groupKindSelect.addEventListener("change", onGroupKindChange);
    dom.groupTitleInput.addEventListener("input", renderGroupEditorSummary);
    dom.groupPublicCheckbox.addEventListener("change", renderGroupEditorSummary);
    dom.groupCommentsCheckbox.addEventListener("change", renderGroupEditorSummary);
    dom.groupForumCheckbox.addEventListener("change", renderGroupEditorSummary);
    dom.groupAvatarInput.addEventListener("change", onGroupAvatarSelected);
    dom.groupRemoveAvatarButton.addEventListener("click", onRemoveGroupAvatarClick);
    dom.copyGroupInviteButton.addEventListener("click", onCopyGroupInviteClick);
    dom.groupMemberSearchInput.addEventListener("input", onGroupMemberSearchInput);
    dom.groupMemberSearchResults.addEventListener("click", onGroupMemberSearchResultsClick);
    dom.groupSelectedMembers.addEventListener("click", onSelectedMembersClick);
    dom.groupMemberList.addEventListener("click", onGroupMemberListClick);
    dom.groupLeaveButton.addEventListener("click", onLeaveGroupClick);
    dom.groupDeleteButton.addEventListener("click", onDeleteGroupClick);
    dom.callRejectButton.addEventListener("click", onRejectCallClick);
    dom.callAnswerButton.addEventListener("click", onAnswerCallClick);
    dom.callMuteButton.addEventListener("click", onMuteCallClick);
    dom.callVideoToggleButton.addEventListener("click", onToggleCallCameraClick);
    dom.callScreenShareButton.addEventListener("click", onCallScreenShareClick);
    dom.callHangupButton.addEventListener("click", onHangupCallClick);
    dom.callDebugToggleButton.addEventListener("click", onCallDebugToggleClick);
    dom.callExpandButton.addEventListener("click", onCallExpandToggleClick);
    dom.callMicrophoneSelect.addEventListener("change", onCallMicrophoneChange);
    dom.callCameraSelect.addEventListener("change", onCallCameraChange);
    dom.callSpeakerSelect.addEventListener("change", onCallSpeakerChange);
    if (navigator.mediaDevices?.addEventListener) {
      navigator.mediaDevices.addEventListener("devicechange", () => {
        void refreshCallDeviceOptions();
      });
    }
    window.addEventListener("focus", onWindowFocus);
    document.addEventListener("keydown", onDocumentKeyDown);
    document.addEventListener("visibilitychange", onVisibilityChange);
  }

  function restoreConfig() {
    try {
      const raw = localStorage.getItem(STORAGE_CONFIG_KEY);
      if (!raw) {
        state.apiBase = DEFAULT_API_BASE;
        return;
      }
      const parsed = JSON.parse(raw);
      state.apiBase = normalizedApiBase(parsed.apiBase) || DEFAULT_API_BASE;
    } catch (error) {
      state.apiBase = DEFAULT_API_BASE;
    }
  }

  function persistConfig() {
    localStorage.setItem(
      STORAGE_CONFIG_KEY,
      JSON.stringify({
        apiBase: state.apiBase,
      }),
    );
  }

  function updateApiBaseInput() {
    dom.apiBaseInput.value = state.apiBase;
  }

  function restoreSession() {
    try {
      const raw = localStorage.getItem(STORAGE_SESSION_KEY);
      if (!raw) {
        state.session = null;
        return;
      }
      const parsed = JSON.parse(raw);
      if (!parsed || !parsed.accessToken || !parsed.refreshToken) {
        state.session = null;
        return;
      }
      state.session = parsed;
      state.lastRealtimeSeq = Number(parsed.lastRealtimeSeq || 0) || 0;
    } catch (error) {
      state.session = null;
    }
  }

  function persistSession() {
    if (!state.session) {
      localStorage.removeItem(STORAGE_SESSION_KEY);
      return;
    }
    localStorage.setItem(
      STORAGE_SESSION_KEY,
      JSON.stringify({
        ...state.session,
        lastRealtimeSeq: state.lastRealtimeSeq,
      }),
    );
  }

  function clearSession() {
    stopCallPolling();
    teardownCurrentCall({ preserveStatus: false });
    state.session = null;
    state.user = null;
    state.chats = [];
    state.devices = [];
    state.activeChatId = null;
    state.messagesByChatId = new Map();
    state.searchResults = [];
    state.presenceByUserId = new Map();
    state.typingByChatId = new Map();
    state.queuedAttachments = [];
    clearQueuedVoiceMessage();
    state.editingMessageId = null;
    state.editingOriginalText = "";
    state.replyingToMessageId = null;
    state.replyingToPreview = null;
    state.lastRealtimeSeq = 0;
    state.settingsModalOpen = false;
    state.groupModalOpen = false;
    state.groupMemberSearchResults = [];
    state.groupEditor = {
      mode: "create",
      chatId: null,
      kind: "group",
      selectedMemberIds: [],
      selectedMembers: [],
      pendingAvatarFile: null,
      pendingAvatarPreviewUrl: null,
    };
    persistSession();
  }

  async function onLoginSubmit(event) {
    event.preventDefault();
    const identifier = dom.loginIdentifier.value.trim();
    const password = dom.loginPassword.value;
    state.apiBase = normalizedApiBase(dom.apiBaseInput.value) || DEFAULT_API_BASE;
    persistConfig();

    if (!identifier || !password) {
      setAuthStatus("Enter your login identifier and password.");
      return;
    }

    toggleLoginBusy(true);
    setAuthStatus("Signing in…");
    try {
      const payload = await request("/auth/login", {
        method: "POST",
        auth: false,
        body: {
          identifier,
          password,
        },
      });
      applySessionPayload(payload);
      setAuthStatus("");
      await bootstrapAuthenticatedApp();
    } catch (error) {
      setAuthStatus(humanizeApiError(error, "Could not sign in. Check your credentials and try again."));
    } finally {
      toggleLoginBusy(false);
    }
  }

  async function bootstrapAuthenticatedApp() {
    try {
      await ensureFreshSession();
      await fetchCurrentUser();
      await loadChats();
      showClientScreen();
      connectRealtime();
      startCallPolling();
      renderAll();
      const initialChat = state.activeChatId || (state.chats[0] && state.chats[0].id);
      if (initialChat) {
        await openChat(initialChat);
      }
      void pollCallListNow(true);
    } catch (error) {
      clearSession();
      showAuthScreen();
      setAuthStatus(humanizeApiError(error, "The saved session could not be restored. Please sign in again."));
    }
  }

  async function ensureFreshSession() {
    if (!state.session) {
      throw new Error("missing_session");
    }
    const me = await request("/auth/me");
    state.user = me;
    return me;
  }

  async function fetchCurrentUser() {
    const me = await request("/auth/me");
    state.user = me;
    return me;
  }

  async function onRefreshClick() {
    if (!state.session) {
      return;
    }
    setComposerStatus("Refreshing chats…");
    try {
      await loadChats();
      if (state.activeChatId) {
        await loadMessages(state.activeChatId, { force: true });
      }
      setComposerStatus("Chats updated.");
      window.setTimeout(() => setComposerStatus(""), 1200);
    } catch (error) {
      setComposerStatus(humanizeApiError(error, "Could not refresh right now."));
    }
  }

  function onLogoutClick() {
    closeRealtime(true);
    stopCallPolling();
    teardownCurrentCall({ preserveStatus: false });
    clearSession();
    closeSettingsModal({ clearStatus: true });
    closeGroupModal();
    clearComposerState();
    renderAll();
    showAuthScreen();
    setAuthStatus("You have been signed out.");
  }

  async function openSettingsModal() {
    if (!state.user?.id) {
      return;
    }
    state.settingsModalOpen = true;
    dom.settingsModal.classList.remove("hidden");
    syncBodyModalLock();
    populateSettingsForms();
    renderSessionList(true);
    clearSettingsStatuses();
    try {
      await loadDeviceSessions();
      renderSessionList();
    } catch (error) {
      setSettingsSessionsStatus(humanizeApiError(error, "Could not load active sessions right now."));
    }
  }

  function closeSettingsModal(options = {}) {
    state.settingsModalOpen = false;
    dom.settingsModal.classList.add("hidden");
    syncBodyModalLock();
    if (options.clearStatus) {
      clearSettingsStatuses();
    }
  }

  function onSettingsBackdropClick(event) {
    if (event.target === dom.settingsModal) {
      closeSettingsModal();
    }
  }

  function onDocumentKeyDown(event) {
    if (event.key !== "Escape") {
      return;
    }
    if (state.groupModalOpen) {
      closeGroupModal();
      return;
    }
    if (state.settingsModalOpen) {
      closeSettingsModal();
    }
  }

  function syncBodyModalLock() {
    document.body.style.overflow = state.settingsModalOpen || state.groupModalOpen ? "hidden" : "";
  }

  function populateSettingsForms() {
    const profile = state.user?.profile || {};
    const privacySettings = state.user?.privacySettings || {};
    renderAvatar(dom.settingsAvatar, profile.displayName || profile.username || "PM", profile.profilePhotoURL);
    dom.settingsDisplayName.textContent = profile.displayName || "Prime user";
    dom.settingsAccountKind.textContent = humanizeAccountKind(state.user?.accountKind || "standard");
    dom.settingsDisplayNameInput.value = profile.displayName || "";
    dom.settingsUsernameInput.value = profile.username || "";
    dom.settingsBioInput.value = profile.bio || "";
    dom.settingsStatusInput.value = profile.status || "";
    dom.settingsBirthdayInput.value = profile.birthday || "";
    dom.settingsEmailInput.value = profile.email || "";
    dom.settingsPhoneInput.value = profile.phoneNumber || "";
    dom.settingsSocialLinkInput.value = profile.socialLink || "";
    dom.privacyShowEmail.checked = Boolean(privacySettings.showEmail);
    dom.privacyShowPhone.checked = Boolean(privacySettings.showPhoneNumber);
    dom.privacyLastSeen.checked = Boolean(privacySettings.allowLastSeen);
    dom.privacyProfilePhoto.checked = Boolean(privacySettings.allowProfilePhoto);
    dom.privacyCalls.checked = Boolean(privacySettings.allowCallsFromNonContacts);
    dom.privacyGroupInvites.checked = Boolean(privacySettings.allowGroupInvitesFromNonContacts);
    dom.privacyForwardLink.checked = Boolean(privacySettings.allowForwardLinkToProfile);
    dom.privacyGuestRequests.value = privacySettings.guestMessageRequests || "approvalRequired";
    dom.settingsCurrentPasswordInput.value = "";
    dom.settingsNewPasswordInput.value = "";
    dom.settingsAvatarInput.value = "";
    const isGuest = (state.user?.accountKind || "standard") === "guest";
    dom.settingsAvatarInput.disabled = isGuest;
    dom.settingsRemoveAvatarButton.disabled = isGuest || !profile.profilePhotoURL;
  }

  function clearSettingsStatuses() {
    setSettingsAvatarStatus("");
    setSettingsProfileStatus("");
    setSettingsPrivacyStatus("");
    setSettingsPasswordStatus("");
    setSettingsSessionsStatus("");
  }

  function setSettingsAvatarStatus(message) {
    dom.settingsAvatarStatus.textContent = message || "";
  }

  function setSettingsProfileStatus(message) {
    dom.settingsProfileStatus.textContent = message || "";
  }

  function setSettingsPrivacyStatus(message) {
    dom.settingsPrivacyStatus.textContent = message || "";
  }

  function setSettingsPasswordStatus(message) {
    dom.settingsPasswordStatus.textContent = message || "";
  }

  function setSettingsSessionsStatus(message) {
    dom.settingsSessionsStatus.textContent = message || "";
  }

  async function loadDeviceSessions() {
    const sessions = await request("/devices");
    state.devices = Array.isArray(sessions) ? sessions : [];
    return state.devices;
  }

  async function onSettingsAvatarSelected(event) {
    const file = Array.from(event.target.files || [])[0];
    if (!file || !state.user?.id) {
      return;
    }
    setSettingsAvatarStatus("Uploading photo…");
    try {
      const imageBase64 = await fileToBase64(file);
      const user = await request(`/users/${encodeURIComponent(state.user.id)}/avatar`, {
        method: "POST",
        body: {
          image_base64: imageBase64,
        },
      });
      state.user = user;
      populateSettingsForms();
      renderAll();
      await loadChats();
      setSettingsAvatarStatus("Profile photo updated.");
    } catch (error) {
      setSettingsAvatarStatus(humanizeApiError(error, "Could not upload the profile photo."));
    } finally {
      dom.settingsAvatarInput.value = "";
    }
  }

  async function onRemoveAvatarClick() {
    if (!state.user?.id) {
      return;
    }
    setSettingsAvatarStatus("Removing photo…");
    try {
      const user = await request(`/users/${encodeURIComponent(state.user.id)}/avatar`, {
        method: "DELETE",
      });
      state.user = user;
      populateSettingsForms();
      renderAll();
      await loadChats();
      setSettingsAvatarStatus("Profile photo removed.");
    } catch (error) {
      setSettingsAvatarStatus(humanizeApiError(error, "Could not remove the profile photo."));
    }
  }

  async function onSettingsProfileSubmit(event) {
    event.preventDefault();
    if (!state.user?.id) {
      return;
    }
    setSettingsProfileStatus("Saving profile…");
    dom.settingsProfileSaveButton.disabled = true;
    try {
      const currentProfile = state.user?.profile || {};
      const displayName = dom.settingsDisplayNameInput.value.trim() || currentProfile.displayName || currentProfile.username || "Prime User";
      const username = dom.settingsUsernameInput.value.trim() || currentProfile.username || "";
      const payload = {
        display_name: displayName,
        username,
        bio: dom.settingsBioInput.value.trim(),
        status: dom.settingsStatusInput.value.trim(),
        birthday: dom.settingsBirthdayInput.value || null,
        email: dom.settingsEmailInput.value.trim() || null,
        phone_number: dom.settingsPhoneInput.value.trim() || null,
        social_link: dom.settingsSocialLinkInput.value.trim() || null,
      };
      const user = await request(`/users/${encodeURIComponent(state.user.id)}/profile`, {
        method: "PATCH",
        body: payload,
      });
      state.user = user;
      populateSettingsForms();
      renderAll();
      await loadChats();
      setSettingsProfileStatus("Profile saved.");
    } catch (error) {
      setSettingsProfileStatus(humanizeApiError(error, "Could not save the profile right now."));
    } finally {
      dom.settingsProfileSaveButton.disabled = false;
    }
  }

  async function onSettingsPrivacySubmit(event) {
    event.preventDefault();
    if (!state.user?.id) {
      return;
    }
    setSettingsPrivacyStatus("Saving privacy settings…");
    dom.settingsPrivacySaveButton.disabled = true;
    try {
      const privacySettings = await request(`/users/${encodeURIComponent(state.user.id)}/privacy`, {
        method: "PATCH",
        body: {
          privacy_settings: {
            showEmail: dom.privacyShowEmail.checked,
            showPhoneNumber: dom.privacyShowPhone.checked,
            allowLastSeen: dom.privacyLastSeen.checked,
            allowProfilePhoto: dom.privacyProfilePhoto.checked,
            allowCallsFromNonContacts: dom.privacyCalls.checked,
            allowGroupInvitesFromNonContacts: dom.privacyGroupInvites.checked,
            allowForwardLinkToProfile: dom.privacyForwardLink.checked,
            guestMessageRequests: dom.privacyGuestRequests.value,
          },
        },
      });
      state.user = {
        ...state.user,
        privacySettings,
      };
      populateSettingsForms();
      renderAll();
      setSettingsPrivacyStatus("Privacy settings saved.");
    } catch (error) {
      setSettingsPrivacyStatus(humanizeApiError(error, "Could not save privacy settings."));
    } finally {
      dom.settingsPrivacySaveButton.disabled = false;
    }
  }

  async function onSettingsPasswordSubmit(event) {
    event.preventDefault();
    if (!state.user?.id) {
      return;
    }
    const oldPassword = dom.settingsCurrentPasswordInput.value;
    const newPassword = dom.settingsNewPasswordInput.value;
    if (!newPassword.trim()) {
      setSettingsPasswordStatus("Enter a new password first.");
      return;
    }
    setSettingsPasswordStatus("Changing password…");
    dom.settingsPasswordSaveButton.disabled = true;
    try {
      await request(`/users/${encodeURIComponent(state.user.id)}/password`, {
        method: "PATCH",
        body: {
          old_password: oldPassword,
          password: newPassword,
        },
      });
      dom.settingsCurrentPasswordInput.value = "";
      dom.settingsNewPasswordInput.value = "";
      setSettingsPasswordStatus("Password updated.");
    } catch (error) {
      setSettingsPasswordStatus(humanizeApiError(error, "Could not update the password."));
    } finally {
      dom.settingsPasswordSaveButton.disabled = false;
    }
  }

  async function onRevokeOtherSessionsClick() {
    setSettingsSessionsStatus("Revoking other sessions…");
    dom.revokeOtherSessionsButton.disabled = true;
    try {
      const payload = await request("/devices/revoke-others", {
        method: "POST",
        body: {},
      });
      await loadDeviceSessions();
      renderSessionList();
      setSettingsSessionsStatus(`Revoked ${Number(payload?.revoked_count || 0)} other session${Number(payload?.revoked_count || 0) === 1 ? "" : "s"}.`);
    } catch (error) {
      setSettingsSessionsStatus(humanizeApiError(error, "Could not revoke other sessions."));
    } finally {
      dom.revokeOtherSessionsButton.disabled = false;
    }
  }

  async function onSessionListClick(event) {
    const button = event.target.closest("[data-revoke-session-id]");
    if (!button) {
      return;
    }
    const sessionId = button.getAttribute("data-revoke-session-id");
    if (!sessionId) {
      return;
    }
    setSettingsSessionsStatus("Revoking session…");
    button.disabled = true;
    try {
      await request(`/devices/${encodeURIComponent(sessionId)}`, {
        method: "DELETE",
      });
      await loadDeviceSessions();
      renderSessionList();
      setSettingsSessionsStatus("Session revoked.");
    } catch (error) {
      setSettingsSessionsStatus(humanizeApiError(error, "Could not revoke that session."));
      button.disabled = false;
    }
  }

  function renderSessionList(isLoading = false) {
    dom.sessionList.innerHTML = "";
    if (isLoading) {
      const loading = document.createElement("div");
      loading.className = "empty-list";
      loading.textContent = "Loading active sessions…";
      dom.sessionList.appendChild(loading);
      return;
    }
    if (!state.devices.length) {
      const empty = document.createElement("div");
      empty.className = "empty-list";
      empty.textContent = "No active sessions were returned.";
      dom.sessionList.appendChild(empty);
      return;
    }
    state.devices.forEach((device) => {
      const item = document.createElement("div");
      item.className = "session-item";
      const title = [device.deviceName, device.platform].filter(Boolean).join(" · ") || "Prime Messaging session";
      const details = [device.deviceModel, [device.osName, device.osVersion].filter(Boolean).join(" "), device.appVersion].filter(Boolean).join(" · ");
      item.innerHTML = `
        <div class="session-copy">
          <div class="session-meta-row">
            <strong>${escapeHtml(title)}</strong>
            ${device.isCurrent ? '<span class="subtle-pill">Current</span>' : ""}
          </div>
          <span>${escapeHtml(details || "No device metadata")}</span>
          <span>Last active ${escapeHtml(formatDateTime(device.lastActiveAt))}</span>
        </div>
        ${device.isCurrent ? "" : `<button class="ghost-button danger" type="button" data-revoke-session-id="${escapeHtml(device.id)}">Revoke</button>`}
      `;
      dom.sessionList.appendChild(item);
    });
  }

  function resetGroupEditor(kind = "group") {
    cleanupPendingGroupAvatar();
    state.groupMemberSearchResults = [];
    state.groupEditor = {
      mode: "create",
      chatId: null,
      kind,
      selectedMemberIds: [],
      selectedMembers: [],
      pendingAvatarFile: null,
      pendingAvatarPreviewUrl: null,
    };
  }

  function cleanupPendingGroupAvatar() {
    if (state.groupEditor?.pendingAvatarPreviewUrl) {
      URL.revokeObjectURL(state.groupEditor.pendingAvatarPreviewUrl);
    }
  }

  function openGroupModalForCreate(kind = "group") {
    resetGroupEditor(kind);
    state.groupModalOpen = true;
    dom.groupModal.classList.remove("hidden");
    syncBodyModalLock();
    clearGroupStatuses();
    populateGroupEditor(null);
  }

  function openGroupModalForActiveChat() {
    const activeChat = getActiveChat();
    if (!isGroupChat(activeChat)) {
      return;
    }
    openGroupModalForChat(activeChat);
  }

  function openGroupModalForChat(chat) {
    if (!isGroupChat(chat)) {
      return;
    }
    cleanupPendingGroupAvatar();
    state.groupMemberSearchResults = [];
    state.groupEditor = {
      mode: "edit",
      chatId: chat.id,
      kind: normalizedGroupKind(chat),
      selectedMemberIds: [],
      selectedMembers: [],
      pendingAvatarFile: null,
      pendingAvatarPreviewUrl: null,
    };
    state.groupModalOpen = true;
    dom.groupModal.classList.remove("hidden");
    syncBodyModalLock();
    clearGroupStatuses();
    populateGroupEditor(chat);
  }

  function closeGroupModal() {
    state.groupModalOpen = false;
    dom.groupModal.classList.add("hidden");
    if (state.groupMemberSearchAbortController) {
      state.groupMemberSearchAbortController.abort();
      state.groupMemberSearchAbortController = null;
    }
    state.groupMemberSearchResults = [];
    dom.groupMemberSearchInput.value = "";
    cleanupPendingGroupAvatar();
    state.groupEditor.pendingAvatarFile = null;
    state.groupEditor.pendingAvatarPreviewUrl = null;
    syncBodyModalLock();
  }

  function onGroupBackdropClick(event) {
    if (event.target === dom.groupModal) {
      closeGroupModal();
    }
  }

  function populateGroupEditor(chat) {
    const isEdit = Boolean(chat);
    const kind = isEdit ? normalizedGroupKind(chat) : state.groupEditor.kind;
    const communityDetails = isEdit ? chat.communityDetails || {} : {};
    const memberCount = isEdit ? (chat.group?.members || []).length : state.groupEditor.selectedMemberIds.length + 1;
    dom.groupModalTitle.textContent = isEdit ? `${groupKindLabel(kind)} details` : `New ${groupKindLabel(kind).toLowerCase()}`;
    dom.groupBasicsTitle.textContent = isEdit ? `${groupKindLabel(kind)} settings` : "Basics";
    dom.groupBasicsSubtitle.textContent = isEdit
      ? "Update how this space looks and who can join."
      : "Set up the title, visibility and first members.";
    dom.groupKindSelect.value = kind;
    dom.groupTitleInput.value = isEdit ? chat.group?.title || chat.title || "" : "";
    dom.groupPublicCheckbox.checked = Boolean(communityDetails.isPublic);
    dom.groupCommentsCheckbox.checked = Boolean(communityDetails.commentsEnabled);
    dom.groupForumCheckbox.checked = Boolean(communityDetails.forumModeEnabled);
    dom.groupMemberSearchInput.value = "";
    dom.groupMemberSearchResults.innerHTML = "";
    renderGroupEditorSummary(chat);
    renderGroupInvite(chat);
    renderGroupSelectedMembers();
    renderGroupMemberList(chat, memberCount);
    dom.groupSaveButton.textContent = isEdit ? "Save changes" : `Create ${groupKindLabel(kind).toLowerCase()}`;
    dom.groupLeaveButton.classList.toggle("hidden", !isEdit);
    dom.groupDeleteButton.classList.toggle("hidden", !isEdit || !currentUserOwnsGroup(chat));
    dom.groupRemoveAvatarButton.disabled = isEdit ? !chat?.group?.photoURL : !state.groupEditor.pendingAvatarFile;
  }

  function renderGroupEditorSummary(chat) {
    const kind = dom.groupKindSelect.value || state.groupEditor.kind || "group";
    const title = dom.groupTitleInput.value.trim() || (chat?.group?.title || chat?.title || `New ${groupKindLabel(kind)}`);
    const isPublic = dom.groupPublicCheckbox.checked;
    const commentsEnabled = dom.groupCommentsCheckbox.checked;
    const forumEnabled = dom.groupForumCheckbox.checked;
    const memberCount = chat ? (chat.group?.members || []).length : state.groupEditor.selectedMemberIds.length + 1;
    const photoUrl = state.groupEditor.pendingAvatarPreviewUrl || chat?.group?.photoURL || null;
    renderAvatar(dom.groupAvatar, title, photoUrl);
    dom.groupSummaryTitle.textContent = title;
    const summaryParts = [
      isPublic ? "Public link" : "Private",
      kind === "channel" ? `${memberCount} subscriber${memberCount === 1 ? "" : "s"}` : `${memberCount} member${memberCount === 1 ? "" : "s"}`,
    ];
    if (kind === "channel" && commentsEnabled) {
      summaryParts.push("Comments on");
    }
    if (forumEnabled) {
      summaryParts.push("Forum mode");
    }
    dom.groupSummarySubtitle.textContent = summaryParts.join(" · ");
    dom.groupCommentsCheckbox.disabled = kind !== "channel";
  }

  function renderGroupInvite(chat) {
    const inviteLink = chat?.communityDetails?.inviteLink || "";
    dom.groupInviteLink.value = inviteLink || "Invite link will appear after creation";
    dom.copyGroupInviteButton.disabled = !inviteLink;
  }

  function renderGroupSelectedMembers() {
    dom.groupSelectedMembers.innerHTML = "";
    const isCreate = state.groupEditor.mode === "create";
    dom.groupSelectedMembers.classList.toggle("hidden", !isCreate);
    if (!isCreate) {
      return;
    }
    const users = state.groupEditor.selectedMembers || [];
    if (!users.length) {
      const empty = document.createElement("div");
      empty.className = "empty-list";
      empty.textContent = "You can create the space alone or add people now.";
      dom.groupSelectedMembers.appendChild(empty);
      return;
    }
    users.forEach((user) => {
      const profile = user.profile || {};
      const chip = document.createElement("button");
      chip.type = "button";
      chip.className = "selected-member-chip";
      chip.setAttribute("data-selected-member-id", user.id);
      chip.innerHTML = `
        ${avatarHtml(profile.displayName || profile.username || "User", profile.profilePhotoURL, false)}
        <span>${escapeHtml(profile.displayName || profile.username || "Prime user")}</span>
        <span>×</span>
      `;
      dom.groupSelectedMembers.appendChild(chip);
    });
  }

  function renderGroupMemberSearchResults() {
    dom.groupMemberSearchResults.innerHTML = "";
    const query = dom.groupMemberSearchInput.value.trim();
    if (query.length < 2) {
      return;
    }
    if (!state.groupMemberSearchResults.length) {
      const empty = document.createElement("div");
      empty.className = "empty-list";
      empty.textContent = "No people found for this query.";
      dom.groupMemberSearchResults.appendChild(empty);
      return;
    }

    state.groupMemberSearchResults.forEach((user) => {
      const profile = user.profile || {};
      const row = document.createElement("button");
      row.type = "button";
      row.className = "search-result-item";
      row.setAttribute("data-group-add-user-id", user.id);
      row.innerHTML = `
        <div class="chat-item-row">
          ${avatarHtml(profile.displayName || profile.username || "User", profile.profilePhotoURL, false)}
          <div class="chat-item-main">
            <div class="chat-item-title">${escapeHtml(profile.displayName || "Prime user")}</div>
            <div class="chat-item-preview">${escapeHtml(profile.username ? `@${profile.username}` : profile.email || "Add to space")}</div>
          </div>
        </div>
      `;
      dom.groupMemberSearchResults.appendChild(row);
    });
  }

  function renderGroupMemberList(chat, fallbackCount = 1) {
    dom.groupMemberList.innerHTML = "";
    if (!chat) {
      const empty = document.createElement("div");
      empty.className = "empty-list";
      empty.textContent = `This ${groupKindLabel(dom.groupKindSelect.value).toLowerCase()} will start with ${fallbackCount} member${fallbackCount === 1 ? "" : "s"}.`;
      dom.groupMemberList.appendChild(empty);
      dom.groupMembersSubtitle.textContent = "Members will appear here after creation.";
      dom.groupAddPeopleSubtitle.textContent = "Search and preselect people before you create it.";
      return;
    }

    const members = chat.group?.members || [];
    const canManage = currentUserCanManageGroup(chat);
    dom.groupMembersSubtitle.textContent = normalizedGroupKind(chat) === "channel"
      ? `${members.length} subscriber${members.length === 1 ? "" : "s"}`
      : `${members.length} member${members.length === 1 ? "" : "s"}`;
    dom.groupAddPeopleSubtitle.textContent = canManage
      ? "Search for people and add them right away."
      : "You can browse the members of this space here.";

    members.forEach((member) => {
      const row = document.createElement("div");
      row.className = "session-item";
      row.innerHTML = `
        <div class="session-copy">
          <div class="session-meta-row">
            <strong>${escapeHtml(member.displayName || member.username || "Prime user")}</strong>
            <span class="subtle-pill">${escapeHtml(member.role || "member")}</span>
          </div>
          <span>${escapeHtml(member.username ? `@${member.username}` : "No username")}</span>
          <span>Joined ${escapeHtml(formatDateTime(member.joinedAt))}</span>
        </div>
        ${canManage && !idsEqualSafe(member.userID, state.user?.id) ? `<button class="ghost-button danger" type="button" data-remove-group-member-id="${escapeHtml(member.userID)}">Remove</button>` : ""}
      `;
      dom.groupMemberList.appendChild(row);
    });
  }

  function clearGroupStatuses() {
    setGroupStatus("");
    setGroupMemberStatus("");
    setGroupDangerStatus("");
  }

  function setGroupStatus(message) {
    dom.groupStatus.textContent = message || "";
  }

  function setGroupMemberStatus(message) {
    dom.groupMemberStatus.textContent = message || "";
  }

  function setGroupDangerStatus(message) {
    dom.groupDangerStatus.textContent = message || "";
  }

  function onGroupKindChange() {
    state.groupEditor.kind = dom.groupKindSelect.value || "group";
    if (state.groupEditor.kind !== "channel") {
      dom.groupCommentsCheckbox.checked = false;
    }
    renderGroupEditorSummary(getGroupEditorChat());
  }

  async function onGroupMemberSearchInput() {
    const query = dom.groupMemberSearchInput.value.trim();
    if (query.length < 2) {
      state.groupMemberSearchResults = [];
      renderGroupMemberSearchResults();
      return;
    }
    if (state.groupMemberSearchAbortController) {
      state.groupMemberSearchAbortController.abort();
    }
    const controller = new AbortController();
    state.groupMemberSearchAbortController = controller;
    try {
      const users = await request(`/users/search?query=${encodeURIComponent(query)}`, {
        signal: controller.signal,
      });
      if (controller.signal.aborted) {
        return;
      }
      const existingIds = new Set((getGroupEditorChat()?.group?.members || []).map((member) => member.userID));
      const selectedIds = new Set(state.groupEditor.selectedMemberIds);
      state.groupMemberSearchResults = (Array.isArray(users) ? users : []).filter((user) => {
        if (!user?.id || idsEqualSafe(user.id, state.user?.id)) {
          return false;
        }
        if (existingIds.has(user.id)) {
          return false;
        }
        if (selectedIds.has(user.id)) {
          return false;
        }
        return true;
      });
      renderGroupMemberSearchResults();
    } catch (error) {
      if (controller.signal.aborted) {
        return;
      }
      state.groupMemberSearchResults = [];
      renderGroupMemberSearchResults();
    }
  }

  async function onGroupMemberSearchResultsClick(event) {
    const button = event.target.closest("[data-group-add-user-id]");
    if (!button) {
      return;
    }
    const userId = button.getAttribute("data-group-add-user-id");
    if (!userId) {
      return;
    }
    const chat = getGroupEditorChat();
    if (!chat) {
      const user = state.groupMemberSearchResults.find((entry) => idsEqualSafe(entry.id, userId));
      if (!state.groupEditor.selectedMemberIds.includes(userId)) {
        state.groupEditor.selectedMemberIds.push(userId);
        if (user) {
          state.groupEditor.selectedMembers.push(user);
        }
      }
      dom.groupMemberSearchInput.value = "";
      state.groupMemberSearchResults = [];
      renderGroupSelectedMembers();
      renderGroupMemberSearchResults();
      renderGroupEditorSummary(null);
      return;
    }
    setGroupMemberStatus("Adding member…");
    try {
      const updatedChat = await request(`/chats/${encodeURIComponent(chat.id)}/group/members`, {
        method: "POST",
        body: {
          member_ids: [userId],
        },
      });
      upsertChat(updatedChat);
      dom.groupMemberSearchInput.value = "";
      state.groupMemberSearchResults = [];
      openGroupModalForChat(updatedChat);
      setGroupMemberStatus("Member added.");
    } catch (error) {
      setGroupMemberStatus(humanizeApiError(error, "Could not add this person right now."));
    }
  }

  function onSelectedMembersClick(event) {
    const button = event.target.closest("[data-selected-member-id]");
    if (!button) {
      return;
    }
    const userId = button.getAttribute("data-selected-member-id");
    state.groupEditor.selectedMemberIds = state.groupEditor.selectedMemberIds.filter((id) => !idsEqualSafe(id, userId));
    state.groupEditor.selectedMembers = state.groupEditor.selectedMembers.filter((user) => !idsEqualSafe(user.id, userId));
    renderGroupSelectedMembers();
    renderGroupEditorSummary(null);
  }

  async function onGroupBasicsSubmit(event) {
    event.preventDefault();
    const title = dom.groupTitleInput.value.trim();
    const kind = dom.groupKindSelect.value || "group";
    if (!title) {
      setGroupStatus("Enter a title first.");
      return;
    }
    setGroupStatus(state.groupEditor.mode === "create" ? "Creating space…" : "Saving changes…");
    dom.groupSaveButton.disabled = true;
    try {
      if (state.groupEditor.mode === "create") {
        let createdChat = await request("/chats/group", {
          method: "POST",
          body: {
            title,
            member_ids: state.groupEditor.selectedMemberIds,
            mode: "online",
            community_details: buildCommunityDetailsPayload(),
          },
        });
        if (state.groupEditor.pendingAvatarFile) {
          const imageBase64 = await fileToBase64(state.groupEditor.pendingAvatarFile);
          createdChat = await request(`/chats/${encodeURIComponent(createdChat.id)}/group/avatar`, {
            method: "POST",
            body: {
              image_base64: imageBase64,
            },
          });
        }
        upsertChat(createdChat);
        closeGroupModal();
        await openChat(createdChat.id);
      } else {
        const currentChat = getGroupEditorChat();
        if (!currentChat) {
          throw new Error("chat_not_found");
        }
        let updatedChat = await request(`/chats/${encodeURIComponent(currentChat.id)}/group`, {
          method: "PATCH",
          body: {
            title,
          },
        });
        updatedChat = await request(`/chats/${encodeURIComponent(currentChat.id)}/community`, {
          method: "PATCH",
          body: {
            community_details: buildCommunityDetailsPayload(updatedChat.communityDetails),
          },
        });
        upsertChat(updatedChat);
        populateGroupEditor(updatedChat);
        renderAll();
        setGroupStatus("Changes saved.");
      }
    } catch (error) {
      setGroupStatus(humanizeApiError(error, "Could not save this space right now."));
    } finally {
      dom.groupSaveButton.disabled = false;
    }
  }

  async function onGroupAvatarSelected(event) {
    const file = Array.from(event.target.files || [])[0];
    if (!file) {
      return;
    }
    const chat = getGroupEditorChat();
    if (!chat) {
      cleanupPendingGroupAvatar();
      state.groupEditor.pendingAvatarFile = file;
      state.groupEditor.pendingAvatarPreviewUrl = URL.createObjectURL(file);
      dom.groupRemoveAvatarButton.disabled = false;
      renderGroupEditorSummary(null);
      setGroupStatus("Photo will be uploaded after creation.");
      dom.groupAvatarInput.value = "";
      return;
    }
    setGroupStatus("Uploading group photo…");
    try {
      const imageBase64 = await fileToBase64(file);
      const updatedChat = await request(`/chats/${encodeURIComponent(chat.id)}/group/avatar`, {
        method: "POST",
        body: {
          image_base64: imageBase64,
        },
      });
      upsertChat(updatedChat);
      populateGroupEditor(updatedChat);
      renderAll();
      setGroupStatus("Group photo updated.");
    } catch (error) {
      setGroupStatus(humanizeApiError(error, "Could not upload the group photo."));
    } finally {
      dom.groupAvatarInput.value = "";
    }
  }

  async function onRemoveGroupAvatarClick() {
    const chat = getGroupEditorChat();
    if (!chat) {
      cleanupPendingGroupAvatar();
      state.groupEditor.pendingAvatarFile = null;
      state.groupEditor.pendingAvatarPreviewUrl = null;
      dom.groupRemoveAvatarButton.disabled = true;
      renderGroupEditorSummary(null);
      setGroupStatus("");
      return;
    }
    setGroupStatus("Removing group photo…");
    try {
      const updatedChat = await request(`/chats/${encodeURIComponent(chat.id)}/group/avatar`, {
        method: "DELETE",
        body: {},
      });
      upsertChat(updatedChat);
      populateGroupEditor(updatedChat);
      renderAll();
      setGroupStatus("Group photo removed.");
    } catch (error) {
      setGroupStatus(humanizeApiError(error, "Could not remove the group photo."));
    }
  }

  async function onCopyGroupInviteClick() {
    const link = dom.groupInviteLink.value.trim();
    if (!link || link === "Invite link will appear after creation") {
      return;
    }
    try {
      await navigator.clipboard.writeText(link);
      setGroupStatus("Invite link copied.");
    } catch (error) {
      setGroupStatus("Could not copy the invite link.");
    }
  }

  async function onGroupMemberListClick(event) {
    const button = event.target.closest("[data-remove-group-member-id]");
    if (!button) {
      return;
    }
    const memberId = button.getAttribute("data-remove-group-member-id");
    const chat = getGroupEditorChat();
    if (!chat || !memberId) {
      return;
    }
    setGroupMemberStatus("Removing member…");
    try {
      const updatedChat = await request(`/chats/${encodeURIComponent(chat.id)}/group/members/${encodeURIComponent(memberId)}`, {
        method: "DELETE",
        body: {},
      });
      upsertChat(updatedChat);
      populateGroupEditor(updatedChat);
      renderAll();
      setGroupMemberStatus("Member removed.");
    } catch (error) {
      setGroupMemberStatus(humanizeApiError(error, "Could not remove this member."));
    }
  }

  async function onLeaveGroupClick() {
    const chat = getGroupEditorChat();
    if (!chat) {
      return;
    }
    if (!window.confirm(`Leave ${chat.title || "this space"}?`)) {
      return;
    }
    setGroupDangerStatus("Leaving…");
    try {
      await request(`/chats/${encodeURIComponent(chat.id)}/group/leave`, {
        method: "POST",
        body: {},
      });
      closeGroupModal();
      await loadChats();
      renderAll();
      const fallbackChat = state.chats[0]?.id;
      if (fallbackChat) {
        await openChat(fallbackChat);
      }
    } catch (error) {
      setGroupDangerStatus(humanizeApiError(error, "Could not leave this space."));
    }
  }

  async function onDeleteGroupClick() {
    const chat = getGroupEditorChat();
    if (!chat) {
      return;
    }
    if (!window.confirm(`Delete ${chat.title || "this space"} for everyone?`)) {
      return;
    }
    setGroupDangerStatus("Deleting…");
    try {
      await request(`/chats/${encodeURIComponent(chat.id)}/group`, {
        method: "DELETE",
        body: {},
      });
      closeGroupModal();
      await loadChats();
      renderAll();
      const fallbackChat = state.chats[0]?.id;
      if (fallbackChat) {
        await openChat(fallbackChat);
      }
    } catch (error) {
      setGroupDangerStatus(humanizeApiError(error, "Could not delete this space."));
    }
  }

  function buildCommunityDetailsPayload(existingDetails = null) {
    const kind = dom.groupKindSelect.value || existingDetails?.kind || state.groupEditor.kind || "group";
    return {
      kind,
      isPublic: dom.groupPublicCheckbox.checked,
      commentsEnabled: kind === "channel" ? dom.groupCommentsCheckbox.checked : false,
      forumModeEnabled: dom.groupForumCheckbox.checked,
      inviteCode: existingDetails?.inviteCode,
    };
  }

  function getGroupEditorChat() {
    return state.chats.find((chat) => idsEqualSafe(chat.id, state.groupEditor.chatId)) || null;
  }

  function isGroupChat(chat) {
    return Boolean(chat && chat.type === "group");
  }

  function normalizedGroupKind(chat) {
    return chat?.communityDetails?.kind || "group";
  }

  function groupKindLabel(kind) {
    if (kind === "channel") {
      return "Channel";
    }
    if (kind === "community") {
      return "Community";
    }
    if (kind === "supergroup") {
      return "Supergroup";
    }
    return "Group";
  }

  function currentUserGroupMember(chat) {
    return (chat?.group?.members || []).find((member) => idsEqualSafe(member.userID, state.user?.id)) || null;
  }

  function currentUserCanManageGroup(chat) {
    const role = currentUserGroupMember(chat)?.role;
    return role === "owner" || role === "admin";
  }

  function currentUserOwnsGroup(chat) {
    return idsEqualSafe(chat?.group?.ownerID, state.user?.id);
  }

  function resolveUserById(userId) {
    if (idsEqualSafe(state.user?.id, userId)) {
      return state.user;
    }
    const searchedUser = state.groupMemberSearchResults.find((user) => idsEqualSafe(user.id, userId));
    if (searchedUser) {
      return searchedUser;
    }
    const allParticipants = state.chats.flatMap((chat) => chat.participants || []);
    return allParticipants.find((user) => idsEqualSafe(user.id, userId)) || null;
  }

  async function loadChats() {
    const chats = await request("/chats?mode=online");
    state.chats = Array.isArray(chats) ? chats.slice().sort(compareChats) : [];
    if (state.activeChatId && !state.chats.some((chat) => chat.id === state.activeChatId)) {
      state.activeChatId = null;
    }
    if (!state.activeChatId && state.chats[0]) {
      state.activeChatId = state.chats[0].id;
    }
    renderSidebar();
  }

  async function openChat(chatId) {
    if (!chatId) {
      return;
    }
    const previousChatId = state.activeChatId;
    if (previousChatId && previousChatId !== chatId && state.typingActive) {
      sendTypingStateForChat(previousChatId, false);
      state.typingActive = false;
    }
    if (previousChatId && previousChatId !== chatId) {
      clearComposerState();
      state.dragDepth = 0;
      renderDropZone(false);
    }
    state.activeChatId = chatId;
    lockConversationToBottom(chatId);
    renderConversationScaffold();
    await loadMessages(chatId, { force: true });
    switchRealtimeChatSubscription(previousChatId, chatId);
    renderAll();
    scheduleMarkActiveChatRead();
  }

  async function loadMessages(chatId, options = {}) {
    if (!chatId) {
      return [];
    }
    const existing = state.messagesByChatId.get(chatId);
    if (existing && !options.force) {
      renderConversation();
      return existing;
    }
    const messages = await request(`/messages?chat_id=${encodeURIComponent(chatId)}`);
    const normalized = Array.isArray(messages) ? messages.slice().sort(compareMessages) : [];
    state.messagesByChatId.set(chatId, normalized);
    renderConversation();
    scheduleScrollMessagesToBottom(true);
    return normalized;
  }

  async function onGlobalSearchInput() {
    const query = dom.globalSearch.value.trim();
    renderSidebar();
    if (query.length < 2 || !state.session) {
      state.searchResults = [];
      renderSearchResults();
      return;
    }
    if (state.searchAbortController) {
      state.searchAbortController.abort();
    }
    const controller = new AbortController();
    state.searchAbortController = controller;
    try {
      const users = await request(`/users/search?query=${encodeURIComponent(query)}`, {
        signal: controller.signal,
      });
      if (controller.signal.aborted) {
        return;
      }
      state.searchResults = Array.isArray(users) ? users : [];
      renderSearchResults();
    } catch (error) {
      if (controller.signal.aborted) {
        return;
      }
      state.searchResults = [];
      renderSearchResults();
    }
  }

  async function startDirectChat(otherUserId) {
    try {
      const chat = await request("/chats/direct", {
        method: "POST",
        body: {
          other_user_id: otherUserId,
          mode: "online",
        },
      });
      upsertChat(chat);
      dom.globalSearch.value = "";
      state.searchResults = [];
      renderSearchResults();
      await openChat(chat.id);
    } catch (error) {
      setComposerStatus(humanizeApiError(error, "Could not open the direct chat."));
    }
  }

  async function onComposerSubmit(event) {
    event.preventDefault();
    const activeChat = getActiveChat();
    if (!activeChat) {
      setComposerStatus("Choose a chat first.");
      return;
    }

    const text = dom.composerInput.value.trim();
    const hasVoiceDraft = Boolean(state.queuedVoiceMessage);
    if (!text && state.queuedAttachments.length === 0 && !hasVoiceDraft && !state.editingMessageId) {
      setComposerStatus("Write a message or attach a file.");
      return;
    }
    if (state.editingMessageId && state.queuedAttachments.length > 0) {
      setComposerStatus("Remove queued attachments before saving an edited message.");
      return;
    }
    if (state.editingMessageId && hasVoiceDraft) {
      setComposerStatus("Remove the voice draft before saving an edited message.");
      return;
    }
    if (state.isRecordingVoice) {
      setComposerStatus("Stop recording before sending the message.");
      return;
    }

    dom.sendButton.disabled = true;
    setComposerStatus(state.editingMessageId ? "Saving changes…" : "Sending…");

    try {
      if (state.editingMessageId) {
        const payload = await request(`/messages/${encodeURIComponent(state.editingMessageId)}`, {
          method: "PATCH",
          body: {
            chat_id: activeChat.id,
            text,
          },
        });
        upsertMessage(activeChat.id, payload);
        clearEditingState();
      } else {
        const attachments = await Promise.all(state.queuedAttachments.map(serializeQueuedAttachment));
        const voiceMessage = state.queuedVoiceMessage ? await serializeQueuedVoiceMessage(state.queuedVoiceMessage) : null;
        const payload = await request("/messages/send", {
          method: "POST",
          body: {
            chat_id: activeChat.id,
            text,
            kind: voiceMessage ? "voice" : "text",
            mode: "online",
            client_message_id: createClientId(),
            attachments,
            reply_to_message_id: state.replyingToMessageId,
            voice_message: voiceMessage,
          },
        });
        upsertMessage(activeChat.id, payload);
        clearComposerInput();
      }
      clearQueuedAttachments();
      clearQueuedVoiceMessage();
      clearReplyState();
      sendTypingState(false);
      renderAll();
      lockConversationToBottom(activeChat.id);
      scheduleScrollMessagesToBottom(true);
      setComposerStatus("");
      scheduleMarkActiveChatRead();
    } catch (error) {
      setComposerStatus(humanizeApiError(error, "Could not send the message."));
    } finally {
      dom.sendButton.disabled = false;
    }
  }

  function onFilesSelected(event) {
    queueFiles(Array.from(event.target.files || []));
    dom.fileInput.value = "";
  }

  function onComposerInput() {
    autoSizeComposer();
    sendTypingState(true);
    if (state.typingStopTimer) {
      window.clearTimeout(state.typingStopTimer);
    }
    state.typingStopTimer = window.setTimeout(() => sendTypingState(false), 1800);
  }

  function onComposerKeyDown(event) {
    if (event.key === "Enter" && !event.shiftKey) {
      event.preventDefault();
      dom.composerForm.requestSubmit();
    }
  }

  async function onMessageListClick(event) {
    const startChatButton = event.target.closest("[data-start-chat-user-id]");
    if (startChatButton) {
      await startDirectChat(startChatButton.getAttribute("data-start-chat-user-id"));
      return;
    }

    const chatButton = event.target.closest("[data-chat-id]");
    if (chatButton && !event.target.closest("[data-message-action]") && !event.target.closest("[data-reaction-emoji]")) {
      await openChat(chatButton.getAttribute("data-chat-id"));
      return;
    }

    const reactionButton = event.target.closest("[data-reaction-emoji]");
    if (reactionButton) {
      const messageId = reactionButton.getAttribute("data-message-id");
      const emoji = reactionButton.getAttribute("data-reaction-emoji");
      await toggleReaction(messageId, emoji);
      return;
    }

    const actionButton = event.target.closest("[data-message-action]");
    if (!actionButton) {
      return;
    }
    const action = actionButton.getAttribute("data-message-action");
    const messageId = actionButton.getAttribute("data-message-id");
    const activeChat = getActiveChat();
    if (!activeChat || !messageId) {
      return;
    }

    if (action === "edit") {
      beginEditingMessage(messageId);
      return;
    }

    if (action === "reply") {
      beginReplyToMessage(messageId);
      return;
    }

    if (action === "delete") {
      if (!window.confirm("Delete this message for everyone?")) {
        return;
      }
      try {
        const payload = await request(`/messages/${encodeURIComponent(messageId)}`, {
          method: "DELETE",
          body: {
            chat_id: activeChat.id,
          },
        });
        upsertMessage(activeChat.id, payload);
        renderConversation();
      } catch (error) {
        setComposerStatus(humanizeApiError(error, "Could not delete the message."));
      }
    }
  }

  async function toggleReaction(messageId, emoji) {
    const activeChat = getActiveChat();
    if (!activeChat) {
      return;
    }
    try {
      const payload = await request(`/messages/${encodeURIComponent(messageId)}/reactions`, {
        method: "POST",
        body: {
          chat_id: activeChat.id,
          emoji,
        },
      });
      upsertMessage(activeChat.id, payload);
      renderConversation();
    } catch (error) {
      setComposerStatus(humanizeApiError(error, "Could not update the reaction."));
    }
  }

  function beginEditingMessage(messageId) {
    const activeChat = getActiveChat();
    if (!activeChat) {
      return;
    }
    const messages = state.messagesByChatId.get(activeChat.id) || [];
    const target = messages.find((message) => message.id === messageId);
    if (!target) {
      return;
    }
    clearReplyState();
    state.editingMessageId = target.id;
    state.editingOriginalText = target.text || "";
    dom.composerInput.value = target.text || "";
    autoSizeComposer();
    dom.composerInput.focus();
    renderEditBanner();
  }

  function beginReplyToMessage(messageId) {
    const activeChat = getActiveChat();
    if (!activeChat) {
      return;
    }
    const messages = state.messagesByChatId.get(activeChat.id) || [];
    const target = messages.find((message) => message.id === messageId);
    if (!target || target.deletedForEveryoneAt) {
      return;
    }
    clearEditingState();
    state.replyingToMessageId = target.id;
    state.replyingToPreview = {
      senderDisplayName: state.user && target.senderID === state.user.id ? "You" : target.senderDisplayName || "Prime user",
      previewText: messagePreviewText(target),
    };
    renderReplyBanner();
    dom.composerInput.focus();
  }

  function clearEditingState(options = {}) {
    const shouldResetInput = Boolean(options.resetInput);
    state.editingMessageId = null;
    state.editingOriginalText = "";
    if (shouldResetInput) {
      dom.composerInput.value = "";
      autoSizeComposer();
    }
    renderEditBanner();
    if (!state.queuedAttachments.length) {
      setComposerStatus("");
    }
  }

  function clearReplyState() {
    state.replyingToMessageId = null;
    state.replyingToPreview = null;
    renderReplyBanner();
  }

  function clearComposerInput() {
    dom.composerInput.value = "";
    autoSizeComposer();
    clearEditingState();
  }

  function clearComposerState() {
    clearComposerInput();
    clearQueuedAttachments();
    clearReplyState();
    clearQueuedVoiceMessage();
    setComposerStatus("");
  }

  function removeQueuedAttachment(attachmentId) {
    const item = state.queuedAttachments.find((entry) => entry.id === attachmentId);
    if (item && item.previewUrl) {
      URL.revokeObjectURL(item.previewUrl);
    }
    state.queuedAttachments = state.queuedAttachments.filter((entry) => entry.id !== attachmentId);
    renderQueuedAttachments();
  }

  function clearQueuedAttachments() {
    state.queuedAttachments.forEach((entry) => {
      if (entry.previewUrl) {
        URL.revokeObjectURL(entry.previewUrl);
      }
    });
    state.queuedAttachments = [];
    renderQueuedAttachments();
  }

  function clearQueuedVoiceMessage() {
    if (state.voiceRecorder) {
      state.voiceRecordingDiscardNextStop = true;
      try {
        state.voiceRecorder.stop();
      } catch (error) {
        cleanupVoiceRecordingRuntime();
        state.voiceRecordingDiscardNextStop = false;
      }
      renderVoiceDraft();
      return;
    }
    cleanupVoiceRecordingRuntime();
    if (state.queuedVoiceMessage?.previewUrl) {
      URL.revokeObjectURL(state.queuedVoiceMessage.previewUrl);
    }
    state.queuedVoiceMessage = null;
    state.voiceRecordingDiscardNextStop = false;
    renderVoiceDraft();
  }

  function queueFiles(files) {
    if (!Array.isArray(files) || !files.length) {
      return;
    }
    if (state.isRecordingVoice) {
      setComposerStatus("Stop recording before attaching files.");
      return;
    }
    if (state.queuedVoiceMessage) {
      setComposerStatus("Remove the voice draft before attaching files.");
      return;
    }
    const acceptedFiles = files.filter((file) => file instanceof File);
    if (!acceptedFiles.length) {
      return;
    }
    const nextItems = acceptedFiles.map((file) => ({
      id: createClientId(),
      file,
      previewUrl: file.type.startsWith("image/") || file.type.startsWith("video/") ? URL.createObjectURL(file) : null,
      attachmentType: inferAttachmentType(file),
    }));
    state.queuedAttachments = state.queuedAttachments.concat(nextItems);
    renderQueuedAttachments();
    setComposerStatus(`${acceptedFiles.length} file${acceptedFiles.length > 1 ? "s" : ""} ready to send.`);
  }

  async function onRecordButtonClick() {
    if (state.isRecordingVoice) {
      stopVoiceRecording();
      return;
    }
    if (state.editingMessageId) {
      setComposerStatus("Finish editing before recording a voice message.");
      return;
    }
    if (state.queuedAttachments.length > 0) {
      setComposerStatus("Send or remove queued files before recording a voice message.");
      return;
    }
    if (state.queuedVoiceMessage) {
      setComposerStatus("Send or remove the current voice draft first.");
      return;
    }
    if (!navigator.mediaDevices?.getUserMedia || !window.MediaRecorder) {
      setComposerStatus("This browser does not support voice recording.");
      return;
    }

    try {
      const stream = await navigator.mediaDevices.getUserMedia({ audio: true });
      const mimeType = pickVoiceMimeType();
      const recorder = mimeType ? new MediaRecorder(stream, { mimeType }) : new MediaRecorder(stream);
      state.voiceRecorder = recorder;
      state.voiceRecorderStream = stream;
      state.voiceRecordingChunks = [];
      state.voiceRecordingStartedAt = Date.now();
      state.voiceWaveformSamples = [];
      state.voiceRecordingDiscardNextStop = false;
      state.isRecordingVoice = true;

      recorder.addEventListener("dataavailable", (recordingEvent) => {
        if (recordingEvent.data && recordingEvent.data.size > 0) {
          state.voiceRecordingChunks.push(recordingEvent.data);
        }
      });

      recorder.addEventListener("stop", async () => {
        const discard = state.voiceRecordingDiscardNextStop;
        const mime = recorder.mimeType || mimeType || "audio/webm";
        const chunks = state.voiceRecordingChunks.slice();
        const startedAt = state.voiceRecordingStartedAt;
        const waveformSamples = state.voiceWaveformSamples.slice(0, 96);
        cleanupVoiceRecordingRuntime();
        state.voiceRecordingDiscardNextStop = false;
        if (discard || !chunks.length) {
          renderVoiceDraft();
          return;
        }
        const blob = new Blob(chunks, { type: mime });
        const previewUrl = URL.createObjectURL(blob);
        state.queuedVoiceMessage = {
          id: createClientId(),
          blob,
          previewUrl,
          mimeType: mime,
          durationSeconds: Math.max(1, Math.round((Date.now() - startedAt) / 1000)),
          waveformSamples,
        };
        renderVoiceDraft();
        setComposerStatus("Voice message is ready to send.");
      });

      startVoiceWaveformSampling(stream);
      recorder.start(250);
      state.voiceRecordingTicker = window.setInterval(renderVoiceDraft, 200);
      renderVoiceDraft();
      setComposerStatus("Recording started.");
    } catch (error) {
      cleanupVoiceRecordingRuntime();
      setComposerStatus("Microphone access was denied or unavailable.");
    }
  }

  function stopVoiceRecording() {
    if (!state.voiceRecorder) {
      return;
    }
    try {
      state.voiceRecorder.stop();
    } catch (error) {
      cleanupVoiceRecordingRuntime();
      renderVoiceDraft();
    }
  }

  function cleanupVoiceRecordingRuntime() {
    if (state.voiceRecordingTicker) {
      window.clearInterval(state.voiceRecordingTicker);
      state.voiceRecordingTicker = null;
    }
    if (state.voiceRecordingAnalyserTimer) {
      window.clearInterval(state.voiceRecordingAnalyserTimer);
      state.voiceRecordingAnalyserTimer = null;
    }
    if (state.voiceRecordingAudioContext) {
      try {
        state.voiceRecordingAudioContext.close();
      } catch (error) {
        // ignore
      }
      state.voiceRecordingAudioContext = null;
    }
    if (state.voiceRecorderStream) {
      state.voiceRecorderStream.getTracks().forEach((track) => track.stop());
      state.voiceRecorderStream = null;
    }
    state.voiceRecorder = null;
    state.voiceRecordingChunks = [];
    state.voiceRecordingStartedAt = 0;
    state.isRecordingVoice = false;
    state.voiceWaveformSamples = [];
    updateRecordButton();
  }

  function startVoiceWaveformSampling(stream) {
    const AudioContextCtor = window.AudioContext || window.webkitAudioContext;
    if (!AudioContextCtor) {
      return;
    }
    const audioContext = new AudioContextCtor();
    const source = audioContext.createMediaStreamSource(stream);
    const analyser = audioContext.createAnalyser();
    analyser.fftSize = 256;
    source.connect(analyser);
    state.voiceRecordingAudioContext = audioContext;
    const timeDomain = new Uint8Array(analyser.fftSize);
    state.voiceRecordingAnalyserTimer = window.setInterval(() => {
      analyser.getByteTimeDomainData(timeDomain);
      let peak = 0;
      for (let index = 0; index < timeDomain.length; index += 1) {
        const sample = Math.abs(timeDomain[index] - 128);
        if (sample > peak) {
          peak = sample;
        }
      }
      state.voiceWaveformSamples.push(Math.min(100, Math.round((peak / 128) * 100)));
      if (state.voiceWaveformSamples.length > 96) {
        state.voiceWaveformSamples.shift();
      }
    }, 120);
  }

  function onComposerDragEnter(event) {
    if (!event.dataTransfer?.types?.includes("Files")) {
      return;
    }
    event.preventDefault();
    state.dragDepth += 1;
    renderDropZone(true);
  }

  function onComposerDragOver(event) {
    if (!event.dataTransfer?.types?.includes("Files")) {
      return;
    }
    event.preventDefault();
    event.dataTransfer.dropEffect = "copy";
    renderDropZone(true);
  }

  function onComposerDragLeave(event) {
    if (!event.dataTransfer?.types?.includes("Files")) {
      return;
    }
    event.preventDefault();
    state.dragDepth = Math.max(0, state.dragDepth - 1);
    if (state.dragDepth === 0) {
      renderDropZone(false);
    }
  }

  function onComposerDrop(event) {
    if (!event.dataTransfer?.files?.length) {
      return;
    }
    event.preventDefault();
    state.dragDepth = 0;
    renderDropZone(false);
    queueFiles(Array.from(event.dataTransfer.files));
  }

  async function markActiveChatRead() {
    const chat = getActiveChat();
    if (!chat) {
      return;
    }
    try {
      await request(`/chats/${encodeURIComponent(chat.id)}/read`, {
        method: "POST",
        body: {},
      });
      upsertChat({
        ...chat,
        unreadCount: 0,
      });
    } catch (error) {
      // silently ignore
    }
  }

  function scheduleMarkActiveChatRead() {
    if (state.activeChatReadTimer) {
      window.clearTimeout(state.activeChatReadTimer);
    }
    state.activeChatReadTimer = window.setTimeout(() => {
      markActiveChatRead();
    }, 320);
  }

  function onWindowFocus() {
    if (state.activeChatId) {
      scheduleMarkActiveChatRead();
    }
    void pollCallListNow(true);
    sendPresencePing(true);
  }

  function onVisibilityChange() {
    if (document.visibilityState === "visible") {
      sendPresencePing(false);
      void pollCallListNow(true);
      if (state.activeChatId) {
        scheduleMarkActiveChatRead();
      }
    } else {
      sendTypingState(false);
    }
  }

  function connectRealtime() {
    if (!state.session?.accessToken) {
      return;
    }
    closeRealtime(true);
    setConnectionState("connecting");

    const wsBase = toWebSocketBase(state.apiBase);
    const params = new URLSearchParams();
    params.set("feed", "1");
    params.set("since", String(state.lastRealtimeSeq || 0));
    params.set("access_token", state.session.accessToken);
    if (state.activeChatId) {
      params.append("chat_id", state.activeChatId);
    }

    const socket = new WebSocket(`${wsBase}/realtime?${params.toString()}`);
    state.realtime = socket;
    state.realtimeIntentionalClose = false;

    socket.addEventListener("open", () => {
      state.realtimeReconnectAttempt = 0;
      setConnectionState("online");
      socket.send(
        JSON.stringify({
          action: "hello",
          feed: true,
          chat_ids: state.activeChatId ? [state.activeChatId] : [],
          since: state.lastRealtimeSeq || 0,
        }),
      );
    });

    socket.addEventListener("message", (event) => {
      try {
        const payload = JSON.parse(event.data);
        handleRealtimeEvent(payload);
      } catch (error) {
        // ignore invalid payloads
      }
    });

    socket.addEventListener("close", () => {
      if (state.realtime !== socket) {
        return;
      }
      state.realtime = null;
      if (state.realtimeIntentionalClose) {
        setConnectionState("offline");
        return;
      }
      scheduleRealtimeReconnect();
    });

    socket.addEventListener("error", () => {
      if (state.realtime === socket) {
        setConnectionState("connecting");
      }
    });
  }

  function closeRealtime(intentional) {
    if (state.realtimeReconnectTimer) {
      window.clearTimeout(state.realtimeReconnectTimer);
      state.realtimeReconnectTimer = null;
    }
    state.realtimeIntentionalClose = Boolean(intentional);
    if (state.realtime) {
      try {
        state.realtime.close();
      } catch (error) {
        // ignore
      }
      state.realtime = null;
    }
    if (intentional) {
      setConnectionState("offline");
    }
  }

  function scheduleRealtimeReconnect() {
    state.realtimeReconnectAttempt += 1;
    const timeout = Math.min(10000, 800 * 2 ** (state.realtimeReconnectAttempt - 1));
    setConnectionState("connecting");
    state.realtimeReconnectTimer = window.setTimeout(() => {
      state.realtimeReconnectTimer = null;
      connectRealtime();
    }, timeout);
  }

  function switchRealtimeChatSubscription(previousChatId, nextChatId) {
    if (!state.realtime || state.realtime.readyState !== WebSocket.OPEN) {
      return;
    }
    if (previousChatId && previousChatId !== nextChatId) {
      state.realtime.send(JSON.stringify({ action: "unsubscribe", chat_id: previousChatId }));
    }
    if (nextChatId) {
      state.realtime.send(JSON.stringify({ action: "subscribe", chat_id: nextChatId }));
    }
  }

  function sendPresencePing(force) {
    if (!state.realtime || state.realtime.readyState !== WebSocket.OPEN) {
      return;
    }
    state.realtime.send(
      JSON.stringify({
        action: "presence",
        force: Boolean(force),
      }),
    );
  }

  function sendTypingState(isTyping) {
    const activeChat = getActiveChat();
    if (!activeChat || activeChat.type !== "direct" || activeChat.mode !== "online") {
      return;
    }
    sendTypingStateForChat(activeChat.id, isTyping);
  }

  function sendTypingStateForChat(chatId, isTyping) {
    if (!chatId) {
      return;
    }
    if (!state.realtime || state.realtime.readyState !== WebSocket.OPEN) {
      return;
    }
    if (state.typingActive === isTyping) {
        return;
    }
    state.typingActive = isTyping;
    state.realtime.send(
      JSON.stringify({
        action: "typing",
        chat_id: chatId,
        is_typing: Boolean(isTyping),
      }),
    );
  }

  function startCallPolling() {
    if (!state.session) {
      return;
    }
    if (state.call.listPollTimer) {
      window.clearTimeout(state.call.listPollTimer);
      state.call.listPollTimer = null;
    }
    scheduleCallListPoll(0);
  }

  function stopCallPolling() {
    if (state.call.listPollTimer) {
      window.clearTimeout(state.call.listPollTimer);
      state.call.listPollTimer = null;
    }
    stopCallEventPolling();
    state.call.listPolling = false;
    state.call.eventPolling = false;
    clearCallDurationTicker();
  }

  function scheduleCallListPoll(delayMs) {
    if (!state.session) {
      return;
    }
    if (state.call.listPollTimer) {
      window.clearTimeout(state.call.listPollTimer);
    }
    state.call.listPollTimer = window.setTimeout(() => {
      state.call.listPollTimer = null;
      void pollCallListNow(false);
    }, Math.max(0, Number(delayMs || 0)));
  }

  function getCallListPollingInterval() {
    if (state.call.current) {
      return 1200;
    }
    return document.visibilityState === "visible" ? 2600 : 4200;
  }

  async function pollCallListNow(force) {
    if (!state.session) {
      return;
    }
    if (force && state.call.listPollTimer) {
      window.clearTimeout(state.call.listPollTimer);
      state.call.listPollTimer = null;
    }
    if (state.call.listPolling) {
      return;
    }
    state.call.listPolling = true;
    try {
      const payload = await request("/calls");
      const calls = Array.isArray(payload)
        ? payload.slice().sort((left, right) => new Date(right.createdAt || 0).getTime() - new Date(left.createdAt || 0).getTime())
        : [];
      await syncCallStateFromList(calls);
    } catch (error) {
      if (state.call.current) {
        setCallStatusLine("Could not refresh the live call state right now.");
      }
    } finally {
      state.call.listPolling = false;
      if (state.session) {
        scheduleCallListPoll(getCallListPollingInterval());
      }
    }
  }

  async function syncCallStateFromList(calls) {
    const currentCallId = state.call.current?.id;
    if (currentCallId) {
      const match = calls.find((call) => idsEqualSafe(call.id, currentCallId));
      if (match) {
        applyCurrentCallSnapshot(match);
        return;
      }
      try {
        const latest = await request(`/calls/${encodeURIComponent(currentCallId)}`);
        applyCurrentCallSnapshot(latest);
        if (!isCallActiveState(latest?.state)) {
          teardownCurrentCall({ preserveStatus: false });
        }
      } catch (error) {
        teardownCurrentCall({ preserveStatus: false });
      }
      return;
    }

    const incomingCandidate = calls.find((call) => callDirection(call) === "incoming");
    if (incomingCandidate) {
      installCall(incomingCandidate, { initiatedLocally: false, acceptedLocally: false });
    }
  }

  function stopCallEventPolling() {
    if (state.call.eventPollTimer) {
      window.clearTimeout(state.call.eventPollTimer);
      state.call.eventPollTimer = null;
    }
  }

  function scheduleCallEventPoll(delayMs) {
    if (!state.call.current || !state.session) {
      return;
    }
    if (state.call.eventPollTimer) {
      window.clearTimeout(state.call.eventPollTimer);
    }
    state.call.eventPollTimer = window.setTimeout(() => {
      state.call.eventPollTimer = null;
      void pollCallEventsNow();
    }, Math.max(0, Number(delayMs || 0)));
  }

  function getCallEventPollingInterval() {
    const current = state.call.current;
    if (!current) {
      return 1400;
    }
    if (current.state === "ringing") {
      return 800;
    }
    const connectionState = String(state.call.peerConnection?.connectionState || "").toLowerCase();
    if (!state.call.answerSent || !state.call.offerSent || connectionState === "connecting" || connectionState === "new") {
      return 850;
    }
    return 1300;
  }

  async function pollCallEventsNow() {
    const current = state.call.current;
    if (!current || !state.session) {
      return;
    }
    if (state.call.eventPolling) {
      return;
    }
    state.call.eventPolling = true;
    const callId = current.id;
    try {
      const payload = await request(`/calls/${encodeURIComponent(callId)}/events?since=${encodeURIComponent(String(state.call.lastEventSequence || 0))}`);
      if (!state.call.current || !idsEqualSafe(state.call.current.id, callId)) {
        return;
      }
      const events = Array.isArray(payload) ? payload.slice().sort((left, right) => Number(left.sequence || 0) - Number(right.sequence || 0)) : [];
      for (const event of events) {
        const sequence = Number(event.sequence || 0);
        if (sequence > state.call.lastEventSequence) {
          state.call.lastEventSequence = sequence;
        }
        await handleCallEvent(event, callId);
      }
    } catch (error) {
      if (state.call.current && idsEqualSafe(state.call.current.id, callId)) {
        setCallStatusLine("Live call updates are delayed. Reconnecting…");
      }
    } finally {
      state.call.eventPolling = false;
      if (state.call.current && idsEqualSafe(state.call.current.id, callId)) {
        scheduleCallEventPoll(getCallEventPollingInterval());
      }
    }
  }

  async function onCallButtonClick() {
    await onStartCallRequest("audio");
  }

  async function onVideoCallButtonClick() {
    await onStartCallRequest("video");
  }

  async function onStartCallRequest(kind) {
    const activeChat = getActiveChat();
    if (!activeChat || activeChat.type !== "direct") {
      return;
    }

    if (state.call.current) {
      if (idsEqualSafe(state.call.current.chatID, activeChat.id)) {
        if (callDirection(state.call.current) === "incoming" && state.call.current.state === "ringing") {
          await onRejectCallClick();
        } else {
          await onHangupCallClick();
        }
      } else {
        setComposerStatus("Finish the current browser call before starting another one.");
      }
      return;
    }

    const participant = otherParticipant(activeChat);
    if (!participant?.id) {
      setComposerStatus("This chat does not have a valid call target.");
      return;
    }

    await startBrowserCall(participant.id, activeChat.id, kind || "audio");
  }

  async function startBrowserCall(otherUserId, chatId, kind) {
    const wantsVideo = kind === "video";
    const callKind = "audio";
    state.call.requestedVideoStart = wantsVideo;
    setCallStatusLine(wantsVideo ? "Preparing your call. Video will start after connection…" : "Preparing your microphone…");
    try {
      await prepareLocalMedia({ audio: true, video: false });
      const call = await request("/calls", {
        method: "POST",
        body: {
          callee_id: otherUserId,
          mode: "online",
          kind: callKind,
        },
      });
      installCall(call, { initiatedLocally: true, acceptedLocally: false });
      if (chatId && !idsEqualSafe(state.activeChatId, chatId)) {
        await openChat(chatId);
      }
      await sendInitialOfferForCurrentCall("start_call");
      setCallStatusLine(wantsVideo ? "Calling… camera will turn on after the call connects." : "Calling…");
    } catch (error) {
      setComposerStatus(humanizeApiError(error, "Could not start the call."));
      teardownCurrentCall({ preserveStatus: false });
    }
  }

  async function onAnswerCallClick() {
    const current = state.call.current;
    if (!current) {
      return;
    }
    state.call.actionBusy = true;
    renderCallOverlay();
    setCallStatusLine(String(current.kind || "audio").toLowerCase() === "video" ? "Connecting camera and microphone…" : "Connecting microphone…");
    try {
      await prepareLocalAudio();
      if (String(current.kind || "audio").toLowerCase() === "video") {
        await ensureLocalVideoTrack();
      }
      const accepted = await request(`/calls/${encodeURIComponent(current.id)}/accept`, {
        method: "POST",
        body: {
          user_id: state.user?.id,
        },
      });
      installCall(accepted, { initiatedLocally: false, acceptedLocally: true });
      if (accepted.chatID && !idsEqualSafe(state.activeChatId, accepted.chatID)) {
        await openChat(accepted.chatID);
      }
      await maybeAnswerCurrentCall("accept");
      setCallStatusLine("Call accepted.");
    } catch (error) {
      setCallStatusLine(humanizeApiError(error, "Could not answer the call."));
    } finally {
      state.call.actionBusy = false;
      renderCallOverlay();
    }
  }

  async function onRejectCallClick() {
    const current = state.call.current;
    if (!current) {
      return;
    }
    state.call.actionBusy = true;
    renderCallOverlay();
    try {
      const rejected = await request(`/calls/${encodeURIComponent(current.id)}/reject`, {
        method: "POST",
        body: {
          user_id: state.user?.id,
        },
      });
      applyCurrentCallSnapshot(rejected);
      teardownCurrentCall({ preserveStatus: false });
    } catch (error) {
      setCallStatusLine(humanizeApiError(error, "Could not decline the call."));
    } finally {
      state.call.actionBusy = false;
      renderCallOverlay();
    }
  }

  async function onHangupCallClick() {
    const current = state.call.current;
    if (!current) {
      return;
    }
    state.call.actionBusy = true;
    renderCallOverlay();
    try {
      const ended = await request(`/calls/${encodeURIComponent(current.id)}/hangup`, {
        method: "POST",
        body: {
          user_id: state.user?.id,
        },
      });
      applyCurrentCallSnapshot(ended);
      teardownCurrentCall({ preserveStatus: false });
    } catch (error) {
      setCallStatusLine(humanizeApiError(error, "Could not end the call."));
    } finally {
      state.call.actionBusy = false;
      renderCallOverlay();
    }
  }

  async function onMuteCallClick() {
    if (!state.call.localStream || !state.call.current) {
      return;
    }
    state.call.localMuted = !state.call.localMuted;
    state.call.localStream.getAudioTracks().forEach((track) => {
      track.enabled = !state.call.localMuted;
    });
    renderCallOverlay();
    try {
      await sendCallMediaState();
    } catch (error) {
      setCallStatusLine(humanizeApiError(error, "Could not sync the mute state."));
    }
  }

  async function onToggleCallCameraClick() {
    if (!state.call.current || state.call.actionBusy) {
      return;
    }
    state.call.actionBusy = true;
    renderCallOverlay();
    try {
      if (state.call.localVideoEnabled) {
        await stopLocalVideoTrack();
        setCallStatusLine("Camera turned off.");
      } else {
        await ensureLocalVideoTrack();
        setCallStatusLine("Camera is live.");
      }
    } catch (error) {
      setCallStatusLine(humanizeApiError(error, "Could not update the camera."));
    } finally {
      state.call.actionBusy = false;
      renderCallOverlay();
    }
  }

  async function onCallScreenShareClick() {
    if (!state.call.current || !navigator.mediaDevices?.getDisplayMedia || state.call.actionBusy) {
      return;
    }
    state.call.actionBusy = true;
    renderCallOverlay();
    try {
      if (state.call.localScreenShareEnabled) {
        await stopLocalVideoTrack();
        setCallStatusLine("Screen sharing stopped.");
      } else {
        const displayStream = await navigator.mediaDevices.getDisplayMedia({ video: true, audio: false });
        const screenTrack = displayStream.getVideoTracks()[0] || null;
        if (!screenTrack) {
          throw new Error("screen_share_unavailable");
        }
        const mergedStream = state.call.localStream || new MediaStream();
        mergedStream.getVideoTracks().forEach((track) => {
          track.stop();
          mergedStream.removeTrack(track);
        });
        mergedStream.addTrack(screenTrack);
        state.call.localStream = mergedStream;
        state.call.localVideoEnabled = true;
        state.call.localScreenShareEnabled = true;
        dom.callLocalVideo.srcObject = mergedStream;
        safePlayMediaElement(dom.callLocalVideo);
        if (state.call.peerConnection) {
          bindLocalStreamToPeerConnection(state.call.peerConnection, mergedStream);
        }
        screenTrack.addEventListener("ended", () => {
          if (state.call.localScreenShareEnabled) {
            void stopLocalVideoTrack();
            renderCallOverlay();
          }
        });
        await syncCallLocalVideoState();
        renderCallOverlay();
        setCallStatusLine("Screen sharing is live.");
      }
    } catch (error) {
      setCallStatusLine(humanizeApiError(error, "Could not start screen sharing."));
    } finally {
      state.call.actionBusy = false;
      renderCallOverlay();
    }
  }

  function onCallDebugToggleClick() {
    state.call.showDebugPanel = !state.call.showDebugPanel;
    renderCallOverlay();
  }

  function onCallExpandToggleClick() {
    state.call.expanded = !state.call.expanded;
    renderCallOverlay();
  }

  async function onCallMicrophoneChange() {
    state.call.selectedAudioInputId = dom.callMicrophoneSelect.value || "";
    if (!state.call.current) {
      return;
    }
    try {
      await prepareLocalMedia({ audio: true, video: state.call.localVideoEnabled });
      setCallStatusLine("Microphone switched.");
    } catch (error) {
      setCallStatusLine(humanizeApiError(error, "Could not switch the microphone."));
    }
  }

  async function onCallCameraChange() {
    state.call.selectedVideoInputId = dom.callCameraSelect.value || "";
    if (!state.call.current || !state.call.localVideoEnabled) {
      return;
    }
    try {
      await prepareLocalMedia({ audio: false, video: true });
      await syncCallLocalVideoState();
      setCallStatusLine("Camera switched.");
    } catch (error) {
      setCallStatusLine(humanizeApiError(error, "Could not switch the camera."));
    }
  }

  async function onCallSpeakerChange() {
    state.call.selectedAudioOutputId = dom.callSpeakerSelect.value || "";
    const outputId = state.call.selectedAudioOutputId;
    const elements = [dom.callRemoteAudio, dom.callRemoteVideo];
    try {
      await Promise.all(
        elements.map(async (element) => {
          if (!element || typeof element.setSinkId !== "function") {
            return;
          }
          await element.setSinkId(outputId || "");
        }),
      );
      setCallStatusLine("Speaker switched.");
    } catch (error) {
      setCallStatusLine("This browser does not allow changing the output device here.");
    }
  }

  function installCall(call, options = {}) {
    if (!call || !call.id) {
      return;
    }
    const currentCallId = state.call.current?.id;
    const sameCall = currentCallId && idsEqualSafe(currentCallId, call.id);
    const preservedLocalStream =
      !sameCall && (options.initiatedLocally || options.acceptedLocally) ? state.call.localStream : null;
    if (!sameCall) {
      teardownCurrentCall({ preserveStatus: false, keepPolling: true, preserveLocalStream: preservedLocalStream });
      state.call.initiatedLocally = Boolean(options.initiatedLocally);
      state.call.acceptedLocally = Boolean(options.acceptedLocally);
      state.call.offerSent = false;
      state.call.answerSent = false;
      state.call.offerInFlight = false;
      state.call.answerInFlight = false;
      state.call.localOfferSDP = "";
      state.call.localAnswerSDP = "";
      state.call.localMuted = false;
      state.call.localVideoEnabled = false;
      state.call.localScreenShareEnabled = false;
      state.call.remoteMuted = false;
      state.call.remoteVideoEnabled = false;
      state.call.requestedVideoStart = Boolean(options.initiatedLocally) ? state.call.requestedVideoStart : false;
      state.call.pendingRemoteCandidates = [];
      state.call.pendingRemoteOfferSDP = null;
      state.call.connectionLabel = call.state === "ringing" ? "Ringing" : "Connecting";
      state.call.statusLine = "";
      state.call.debugLines = [];
      state.call.lastEventSequence = 0;
      if (preservedLocalStream) {
        state.call.localStream = preservedLocalStream;
        dom.callLocalAudio.srcObject = preservedLocalStream;
        dom.callLocalVideo.srcObject = preservedLocalStream;
        safePlayMediaElement(dom.callLocalAudio);
        safePlayMediaElement(dom.callLocalVideo);
      }
    } else {
      state.call.initiatedLocally = state.call.initiatedLocally || Boolean(options.initiatedLocally);
      state.call.acceptedLocally = state.call.acceptedLocally || Boolean(options.acceptedLocally);
    }

    applyCurrentCallSnapshot(call);
    void refreshCallDeviceOptions();
    renderCallButton();
    renderCallOverlay();
    startCallEventMonitoring();

    if (state.call.current?.chatID && (options.openChat || options.acceptedLocally || options.initiatedLocally)) {
      void maybeOpenChatForCurrentCall();
    }

    if (callDirection(call) === "outgoing" && state.call.initiatedLocally && !state.call.offerSent) {
      void sendInitialOfferForCurrentCall("install");
    }
    if (callDirection(call) === "incoming" && state.call.acceptedLocally) {
      void maybeAnswerCurrentCall("install");
    }
  }

  function applyCurrentCallSnapshot(call) {
    if (!call || !call.id) {
      return;
    }
    state.call.current = call;
    if (call.latestRemoteOfferSDP) {
      state.call.pendingRemoteOfferSDP = normalizeSDP(call.latestRemoteOfferSDP);
    }
    state.call.remoteVideoEnabled = String(call.kind || "audio").toLowerCase() === "video" ? state.call.remoteVideoEnabled : false;
    if (call.answeredAt) {
      state.call.startedAtMs = new Date(call.answeredAt).getTime();
    } else if (!state.call.startedAtMs && call.createdAt) {
      state.call.startedAtMs = new Date(call.createdAt).getTime();
    }
    syncCallDurationTicker();
    if (!isCallActiveState(call.state)) {
      clearCallDurationTicker();
    }
    renderCallButton();
    renderCallOverlay();
  }

  function startCallEventMonitoring() {
    stopCallEventPolling();
    if (!state.call.current) {
      return;
    }
    scheduleCallEventPoll(0);
  }

  async function prepareLocalMedia(options = {}) {
    const needsAudio = options.audio !== false;
    const needsVideo = Boolean(options.video);
    if (!navigator.mediaDevices?.getUserMedia) {
      const error = new Error("browser_calling_unsupported");
      error.payload = { error: "browser_calling_unsupported" };
      throw error;
    }
    if (
      state.call.localStream &&
      (!needsAudio || state.call.localStream.getAudioTracks().length > 0) &&
      (!needsVideo || state.call.localStream.getVideoTracks().length > 0)
    ) {
      return state.call.localStream;
    }

    try {
      const constraints = {
        audio: needsAudio
          ? {
              echoCancellation: true,
              noiseSuppression: true,
              autoGainControl: true,
              ...(state.call.selectedAudioInputId ? { deviceId: { exact: state.call.selectedAudioInputId } } : {}),
            }
          : false,
        video: needsVideo
          ? {
              facingMode: "user",
              ...(state.call.selectedVideoInputId ? { deviceId: { exact: state.call.selectedVideoInputId } } : {}),
            }
          : false,
      };
      const stream = await navigator.mediaDevices.getUserMedia(constraints);
      const mergedStream = state.call.localStream || new MediaStream();
      if (needsAudio) {
        mergedStream.getAudioTracks().forEach((track) => {
          if (track.readyState !== "ended") {
            track.stop();
          }
          mergedStream.removeTrack(track);
        });
        stream.getAudioTracks().forEach((track) => mergedStream.addTrack(track));
      }
      if (needsVideo) {
        mergedStream.getVideoTracks().forEach((track) => {
          if (track.readyState !== "ended") {
            track.stop();
          }
          mergedStream.removeTrack(track);
        });
        stream.getVideoTracks().forEach((track) => mergedStream.addTrack(track));
      }
      state.call.localStream = mergedStream;
      state.call.localMuted = needsAudio ? false : state.call.localMuted;
      state.call.localVideoEnabled = mergedStream.getVideoTracks().some((track) => track.enabled);
      dom.callLocalAudio.srcObject = mergedStream;
      dom.callLocalVideo.srcObject = mergedStream;
      safePlayMediaElement(dom.callLocalAudio);
      safePlayMediaElement(dom.callLocalVideo);
      if (state.call.peerConnection) {
        bindLocalStreamToPeerConnection(state.call.peerConnection, mergedStream);
      }
      await refreshCallDeviceOptions();
      renderCallOverlay();
      return mergedStream;
    } catch (error) {
      const wrapped = new Error(needsVideo ? "media_permission_denied" : "microphone_permission_denied");
      wrapped.payload = { error: needsVideo ? "media_permission_denied" : "microphone_permission_denied" };
      throw wrapped;
    }
  }

  async function prepareLocalAudio() {
    return prepareLocalMedia({ audio: true, video: false });
  }

  async function ensureLocalVideoTrack() {
    const stream = await prepareLocalMedia({ audio: false, video: true });
    const videoTrack = stream.getVideoTracks()[0] || null;
    state.call.localVideoEnabled = Boolean(videoTrack && videoTrack.enabled);
    dom.callLocalVideo.srcObject = stream;
    safePlayMediaElement(dom.callLocalVideo);
    await syncCallLocalVideoState();
    return videoTrack;
  }

  async function stopLocalVideoTrack() {
    if (!state.call.localStream) {
      state.call.localVideoEnabled = false;
      await syncCallLocalVideoState();
      return;
    }
    state.call.localStream.getVideoTracks().forEach((track) => {
      track.stop();
      state.call.localStream.removeTrack(track);
    });
    if (state.call.peerConnection) {
      const videoSender = state.call.peerConnection.getSenders().find((sender) => sender.track?.kind === "video");
      if (videoSender) {
        try {
          videoSender.replaceTrack(null);
        } catch (error) {
          // ignore sender detach failures
        }
      }
    }
    state.call.localVideoEnabled = false;
    state.call.localScreenShareEnabled = false;
    dom.callLocalVideo.srcObject = state.call.localStream;
    await syncCallLocalVideoState();
    renderCallOverlay();
  }

  async function syncCallLocalVideoState() {
    const localVideoTrack = state.call.localStream?.getVideoTracks?.()[0] || null;
    state.call.localVideoEnabled = Boolean(localVideoTrack && localVideoTrack.enabled);
    try {
      await sendCallMediaState();
    } catch (error) {
      setCallStatusLine(humanizeApiError(error, "Could not sync the camera state."));
    }
  }

  async function refreshCallDeviceOptions() {
    if (!navigator.mediaDevices?.enumerateDevices) {
      return;
    }
    try {
      const devices = await navigator.mediaDevices.enumerateDevices();
      state.call.availableDevices = {
        audioinput: devices.filter((device) => device.kind === "audioinput"),
        videoinput: devices.filter((device) => device.kind === "videoinput"),
        audiooutput: devices.filter((device) => device.kind === "audiooutput"),
      };
      const currentAudioTrack = state.call.localStream?.getAudioTracks?.()[0] || null;
      const currentVideoTrack = state.call.localStream?.getVideoTracks?.()[0] || null;
      const audioSettings = currentAudioTrack?.getSettings?.() || {};
      const videoSettings = currentVideoTrack?.getSettings?.() || {};
      if (!state.call.selectedAudioInputId && audioSettings.deviceId) {
        state.call.selectedAudioInputId = audioSettings.deviceId;
      }
      if (!state.call.selectedVideoInputId && videoSettings.deviceId) {
        state.call.selectedVideoInputId = videoSettings.deviceId;
      }
      renderCallDeviceOptions();
    } catch (error) {
      // ignore device enumeration errors
    }
  }

  function renderCallDeviceOptions() {
    fillSelectWithDevices(
      dom.callMicrophoneSelect,
      state.call.availableDevices.audioinput,
      state.call.selectedAudioInputId,
      "Default microphone",
    );
    fillSelectWithDevices(
      dom.callCameraSelect,
      state.call.availableDevices.videoinput,
      state.call.selectedVideoInputId,
      "Default camera",
    );
    fillSelectWithDevices(
      dom.callSpeakerSelect,
      state.call.availableDevices.audiooutput,
      state.call.selectedAudioOutputId,
      "Default speaker",
    );
  }

  function fillSelectWithDevices(select, devices, selectedId, fallbackLabel) {
    if (!select) {
      return;
    }
    const normalizedDevices = Array.isArray(devices) ? devices : [];
    select.innerHTML = normalizedDevices
      .map((device, index) => {
        const label = device.label || `${fallbackLabel} ${index + 1}`;
        const selected = selectedId && device.deviceId === selectedId ? " selected" : "";
        return `<option value="${escapeHtml(device.deviceId || "")}"${selected}>${escapeHtml(label)}</option>`;
      })
      .join("");
    if (!select.innerHTML) {
      select.innerHTML = `<option value="">${escapeHtml(fallbackLabel)}</option>`;
    }
    if (!selectedId && select.options.length) {
      select.value = select.options[0].value;
    } else if (selectedId) {
      select.value = selectedId;
    }
    select.disabled = normalizedDevices.length <= 1;
  }

  async function ensureCallPeerConnection() {
    if (state.call.peerConnection) {
      return state.call.peerConnection;
    }
    const iceServers = await fetchCallIceServers();
    state.call.iceServers = iceServers;
    const peerConnection = new RTCPeerConnection({ iceServers });
    const remoteStream = new MediaStream();
    state.call.peerConnection = peerConnection;
    state.call.remoteStream = remoteStream;
    dom.callRemoteAudio.srcObject = remoteStream;
    dom.callRemoteVideo.srcObject = remoteStream;
    safePlayMediaElement(dom.callRemoteAudio);
    safePlayMediaElement(dom.callRemoteVideo);
    appendCallDebug(`pc.create ice=${iceServers.length}`);

    if (state.call.localStream) {
      bindLocalStreamToPeerConnection(peerConnection, state.call.localStream);
    }
    if (!peerConnection.getTransceivers().some((transceiver) => transceiver.receiver?.track?.kind === "audio" || transceiver.sender?.track?.kind === "audio")) {
      peerConnection.addTransceiver("audio", { direction: "sendrecv" });
      appendCallDebug("pc.transceiver audio=sendrecv");
    }
    if (!peerConnection.getTransceivers().some((transceiver) => transceiver.receiver?.track?.kind === "video" || transceiver.sender?.track?.kind === "video")) {
      peerConnection.addTransceiver("video", { direction: "sendrecv" });
      appendCallDebug("pc.transceiver video=sendrecv");
    }

    peerConnection.addEventListener("icecandidate", (event) => {
      if (!event.candidate || !state.call.current) {
        return;
      }
      appendCallDebug(`ice.local ${event.candidate.type || "candidate"}`);
      void sendCallIceCandidate(event.candidate);
    });

    peerConnection.addEventListener("track", (event) => {
      if (event.streams?.[0]) {
        event.streams[0].getTracks().forEach((track) => {
          if (!remoteStream.getTracks().some((existing) => existing.id === track.id)) {
            remoteStream.addTrack(track);
          }
        });
      } else if (event.track && !remoteStream.getTracks().some((existing) => existing.id === event.track.id)) {
        remoteStream.addTrack(event.track);
      }
      safePlayMediaElement(dom.callRemoteAudio);
      safePlayMediaElement(dom.callRemoteVideo);
      state.call.connectionLabel = "Connected";
      if (event.track?.kind === "video") {
        state.call.remoteVideoEnabled = true;
        event.track.addEventListener("ended", () => {
          state.call.remoteVideoEnabled = false;
          renderCallOverlay();
        });
      }
      appendCallDebug(`track.remote kind=${event.track?.kind || "unknown"}`);
      renderCallOverlay();
    });

    const updateConnectionLabel = () => {
      const value = String(peerConnection.connectionState || peerConnection.iceConnectionState || "new").toLowerCase();
      appendCallDebug(
        `pc.state signaling=${peerConnection.signalingState} conn=${peerConnection.connectionState} ice=${peerConnection.iceConnectionState}`,
      );
      switch (value) {
        case "connected":
          state.call.connectionLabel = "Connected";
          break;
        case "connecting":
        case "checking":
          state.call.connectionLabel = "Connecting";
          break;
        case "failed":
          state.call.connectionLabel = "Connection failed";
          break;
        case "disconnected":
          state.call.connectionLabel = "Reconnecting";
          break;
        case "closed":
          state.call.connectionLabel = "Closed";
          break;
        default:
          state.call.connectionLabel = "Waiting";
          break;
      }
      renderCallOverlay();
    };

    peerConnection.addEventListener("connectionstatechange", updateConnectionLabel);
    peerConnection.addEventListener("iceconnectionstatechange", updateConnectionLabel);

    return peerConnection;
  }

  function bindLocalStreamToPeerConnection(peerConnection, stream) {
    const existingSenders = peerConnection.getSenders();
    stream.getTracks().forEach((track) => {
      const sender = existingSenders.find((entry) => entry.track && entry.track.kind === track.kind);
      if (sender) {
        if (sender.track !== track) {
          sender.replaceTrack(track);
          appendCallDebug(`pc.sender.replace ${track.kind}`);
        }
      } else {
        peerConnection.addTrack(track, stream);
        appendCallDebug(`pc.sender.add ${track.kind}`);
      }
    });
  }

  async function fetchCallIceServers() {
    try {
      const payload = await request("/calls/ice-config");
      const servers = Array.isArray(payload?.iceServers) ? payload.iceServers : [];
      const normalized = servers
        .map((entry) => {
          const urls = Array.isArray(entry.urls) && entry.urls.length ? entry.urls : entry.url ? [entry.url] : [];
          if (!urls.length) {
            return null;
          }
          return {
            urls,
            username: entry.username || undefined,
            credential: entry.credential || undefined,
          };
        })
        .filter(Boolean);
      return mergeWithFallbackIceServers(normalized);
    } catch (error) {
      return FALLBACK_WEB_ICE_SERVERS.slice();
    }
  }

  function mergeWithFallbackIceServers(servers) {
    const normalized = Array.isArray(servers) ? servers.filter(Boolean) : [];
    const hasTurn = normalized.some((server) =>
      (Array.isArray(server.urls) ? server.urls : [server.urls]).some((url) => String(url || "").toLowerCase().startsWith("turn")),
    );
    if (hasTurn) {
      return normalized;
    }
    return normalized.concat(FALLBACK_WEB_ICE_SERVERS.filter((fallback) =>
      !fallback.urls.some((url) => normalized.some((server) => (Array.isArray(server.urls) ? server.urls : [server.urls]).includes(url))),
    ));
  }

  async function sendInitialOfferForCurrentCall(reason) {
    const current = state.call.current;
    if (!current || callDirection(current) !== "outgoing" || state.call.offerSent || state.call.offerInFlight) {
      return;
    }
    state.call.offerInFlight = true;
    try {
      await prepareLocalMedia({
        audio: true,
        video: String(current.kind || "audio").toLowerCase() === "video",
      });
      const peerConnection = await ensureCallPeerConnection();
      if (peerConnection.signalingState !== "stable") {
        appendCallDebug(`offer.skip signaling=${peerConnection.signalingState}`);
        return;
      }
      const offer = await peerConnection.createOffer({
        offerToReceiveAudio: true,
        offerToReceiveVideo: true,
      });
      appendCallDebug(`offer.create reason=${reason} size=${String(offer.sdp || "").length}`);
      await peerConnection.setLocalDescription(offer);
      appendCallDebug(`offer.local_set signaling=${peerConnection.signalingState}`);
      state.call.localOfferSDP = normalizeSDP(offer.sdp);
      appendCallDebug(`offer.local_sdp ${summarizeSDP(state.call.localOfferSDP)}`);
      await dispatchCallSDPSignalWithRetry("offer", state.call.localOfferSDP, 5, 420);
      state.call.offerSent = true;
      state.call.connectionLabel = "Waiting for answer";
      appendCallDebug("offer.sent");
      renderCallOverlay();
    } catch (error) {
      appendCallDebug(`offer.error ${String(error?.message || error)}`);
      setCallStatusLine(humanizeApiError(error, `Could not send the call offer (${reason}).`));
    } finally {
      state.call.offerInFlight = false;
    }
  }

  async function maybeAnswerCurrentCall(source) {
    const current = state.call.current;
    if (!current || callDirection(current) !== "incoming" || !state.call.acceptedLocally || state.call.answerInFlight) {
      return;
    }
    state.call.answerInFlight = true;
    try {
      const offerSDP = normalizeSDP(await resolveOfferForCurrentCall());
      if (!offerSDP || state.call.answerSent) {
        return;
      }
      await prepareLocalMedia({
        audio: true,
        video: String(current.kind || "audio").toLowerCase() === "video",
      });
      const peerConnection = await ensureCallPeerConnection();
      appendCallDebug(
        `answer.start source=${source} signaling=${peerConnection.signalingState} offer=${summarizeSDP(offerSDP)}`,
      );
      appendCallDebug(`offer.remote_raw ${summarizeRawSDP(state.call.pendingRemoteOfferSDP || state.call.current?.latestRemoteOfferSDP || offerSDP)}`);
      appendCallDebug(`offer.remote_sdp ${summarizeSDP(offerSDP)}`);
      appendCallDebug(`offer.remote_invalid ${findInvalidSDPLine(state.call.pendingRemoteOfferSDP || state.call.current?.latestRemoteOfferSDP || offerSDP)}`);
      if (!peerConnection.remoteDescription && peerConnection.signalingState === "stable") {
        await peerConnection.setRemoteDescription({ type: "offer", sdp: offerSDP });
        appendCallDebug("offer.remote_set");
      }
      await flushPendingRemoteCandidates();
      const answer = await peerConnection.createAnswer();
      appendCallDebug(`answer.create size=${String(answer.sdp || "").length}`);
      await peerConnection.setLocalDescription(answer);
      appendCallDebug(`answer.local_set signaling=${peerConnection.signalingState}`);
      state.call.localAnswerSDP = normalizeSDP(answer.sdp);
      appendCallDebug(`answer.local_sdp ${summarizeSDP(state.call.localAnswerSDP)}`);
      await dispatchCallSDPSignalWithRetry("answer", state.call.localAnswerSDP, 6, 420);
      state.call.answerSent = true;
      state.call.pendingRemoteOfferSDP = null;
      state.call.connectionLabel = "Connecting";
      appendCallDebug("answer.sent");
      renderCallOverlay();
    } catch (error) {
      appendCallDebug(`answer.error ${String(error?.message || error)} invalid=${findInvalidSDPLine(state.call.pendingRemoteOfferSDP || state.call.current?.latestRemoteOfferSDP || "")}`);
      setCallStatusLine(humanizeApiError(error, `Could not finish the browser answer flow (${source}).`));
    } finally {
      state.call.answerInFlight = false;
    }
  }

  async function resolveOfferForCurrentCall() {
    const current = state.call.current;
    if (!current) {
      return "";
    }

    for (let attempt = 1; attempt <= 8; attempt += 1) {
      const cached = normalizeSDP(state.call.pendingRemoteOfferSDP || state.call.current?.latestRemoteOfferSDP || "");
      if (cached) {
        appendCallDebug(`offer.resolve cached attempt=${attempt} size=${cached.length}`);
        return cached;
      }

      try {
        const latestCall = await request(`/calls/${encodeURIComponent(current.id)}`);
        if (latestCall?.latestRemoteOfferSDP) {
          applyCurrentCallSnapshot(latestCall);
          appendCallDebug(`offer.resolve call_snapshot attempt=${attempt}`);
          return normalizeSDP(latestCall.latestRemoteOfferSDP || "");
        }
      } catch (error) {
        // keep waiting; events endpoint may still catch the offer
      }

      try {
        const events = await request(`/calls/${encodeURIComponent(current.id)}/events?since=0`);
        const latestOffer = Array.isArray(events)
          ? events
              .filter((event) => event?.type === "offer" && !idsEqualSafe(event?.senderID, state.user?.id) && event?.sdp)
              .sort((left, right) => Number(right.sequence || 0) - Number(left.sequence || 0))[0]
          : null;
        if (latestOffer?.sdp) {
          state.call.pendingRemoteOfferSDP = normalizeSDP(latestOffer.sdp);
          appendCallDebug(`offer.resolve events attempt=${attempt} seq=${latestOffer.sequence || 0}`);
          return normalizeSDP(latestOffer.sdp || "");
        }
      } catch (error) {
        // ignore and retry
      }

      await sleep(260);
    }

    return "";
  }

  async function applyRemoteAnswerToCurrentCall(sdp) {
    const current = state.call.current;
    const normalizedAnswerSDP = normalizeSDP(sdp);
    if (!current || !normalizedAnswerSDP) {
      return;
    }
    try {
      const peerConnection = await ensureCallPeerConnection();
      appendCallDebug(`answer.remote_apply signaling=${peerConnection.signalingState}`);
      appendCallDebug(`answer.remote_sdp ${summarizeSDP(normalizedAnswerSDP)}`);
      if (peerConnection.signalingState === "stable" && peerConnection.currentRemoteDescription) {
        appendCallDebug("answer.remote_skip_already_stable");
        return;
      }
      if (peerConnection.signalingState !== "have-local-offer") {
        await sleep(140);
      }
      if (!peerConnection.remoteDescription && peerConnection.signalingState === "have-local-offer") {
        await peerConnection.setRemoteDescription({ type: "answer", sdp: normalizedAnswerSDP });
        appendCallDebug("answer.remote_set");
      } else if (peerConnection.currentRemoteDescription) {
        appendCallDebug("answer.remote_skip_has_description");
        return;
      } else {
        throw new Error("invalid_remote_answer_state");
      }
      await flushPendingRemoteCandidates();
      state.call.connectionLabel = "Connecting";
      renderCallOverlay();
    } catch (error) {
      appendCallDebug(`answer.remote_error ${String(error?.message || error)}`);
      setCallStatusLine(humanizeApiError(error, "Could not apply the remote answer."));
    }
  }

  async function dispatchCallSDPSignalWithRetry(type, sdp, maxAttempts, delayMs) {
    const current = state.call.current;
    if (!current || !sdp) {
      throw new Error("missing_call_signal_payload");
    }

    let lastError = null;
    for (let attempt = 1; attempt <= maxAttempts; attempt += 1) {
      try {
        appendCallDebug(`${type}.send attempt=${attempt}`);
        await request(`/calls/${encodeURIComponent(current.id)}/${type}`, {
          method: "POST",
          body: {
            sdp,
          },
        });
        appendCallDebug(`${type}.sent attempt=${attempt}`);
        return;
      } catch (error) {
        lastError = error;
        appendCallDebug(`${type}.send_error attempt=${attempt} code=${String(error?.payload?.error || error?.message || "unknown")}`);
        if (attempt < maxAttempts) {
          await sleep(delayMs);
        }
      }
    }
    throw lastError || new Error(`failed_to_send_${type}`);
  }

  async function sendCallIceCandidate(candidate) {
    const current = state.call.current;
    if (!current || !candidate?.candidate) {
      return;
    }
    try {
      await request(`/calls/${encodeURIComponent(current.id)}/ice`, {
        method: "POST",
        body: {
          candidate: candidate.candidate,
          sdp_mid: candidate.sdpMid,
          sdp_mline_index: candidate.sdpMLineIndex,
        },
      });
      appendCallDebug(`ice.sent mid=${candidate.sdpMid || "0"} line=${candidate.sdpMLineIndex ?? -1}`);
    } catch (error) {
      appendCallDebug(`ice.send_error ${String(error?.message || error)}`);
      setCallStatusLine(humanizeApiError(error, "A network candidate could not be delivered."));
    }
  }

  async function sendCallMediaState() {
    const current = state.call.current;
    if (!current) {
      return;
    }
    await request(`/calls/${encodeURIComponent(current.id)}/media-state`, {
      method: "POST",
      body: {
        isMuted: Boolean(state.call.localMuted),
        isVideoEnabled: Boolean(state.call.localVideoEnabled),
      },
    });
  }

  async function queueOrApplyRemoteIceCandidate(event) {
    const candidatePayload = {
      candidate: event.candidate,
      sdpMid: event.sdpMid,
      sdpMLineIndex: event.sdpMLineIndex,
    };
    const peerConnection = state.call.peerConnection;
    if (!peerConnection || !peerConnection.remoteDescription) {
      state.call.pendingRemoteCandidates.push(candidatePayload);
      appendCallDebug(`ice.queue remote=${event.sdpMid || "0"}/${event.sdpMLineIndex ?? -1}`);
      if (callDirection(state.call.current) === "outgoing" && !state.call.answerSent) {
        void recoverRemoteAnswerIfMissing();
      }
      return;
    }
    try {
      await peerConnection.addIceCandidate(candidatePayload);
      appendCallDebug(`ice.add remote=${event.sdpMid || "0"}/${event.sdpMLineIndex ?? -1}`);
    } catch (error) {
      state.call.pendingRemoteCandidates.push(candidatePayload);
      appendCallDebug(`ice.add_error ${String(error?.message || error)}`);
    }
  }

  async function recoverRemoteAnswerIfMissing() {
    const current = state.call.current;
    const peerConnection = state.call.peerConnection;
    if (!current || !peerConnection) {
      return;
    }
    if (peerConnection.remoteDescription || callDirection(current) !== "outgoing") {
      return;
    }

    try {
      const events = await request(`/calls/${encodeURIComponent(current.id)}/events?since=0`);
      const latestAnswer = Array.isArray(events)
        ? events
            .filter((event) => event?.type === "answer" && !idsEqualSafe(event?.senderID, state.user?.id) && event?.sdp)
            .sort((left, right) => Number(right.sequence || 0) - Number(left.sequence || 0))[0]
        : null;
      if (latestAnswer?.sdp) {
        appendCallDebug(`answer.recover events seq=${latestAnswer.sequence || 0}`);
        await applyRemoteAnswerToCurrentCall(latestAnswer.sdp);
        return;
      }

      const latestCall = await request(`/calls/${encodeURIComponent(current.id)}`);
      if (latestCall?.state) {
        applyCurrentCallSnapshot(latestCall);
      }
    } catch (error) {
      appendCallDebug(`answer.recover_error ${String(error?.payload?.error || error?.message || error)}`);
    }
  }

  async function flushPendingRemoteCandidates() {
    const peerConnection = state.call.peerConnection;
    if (!peerConnection || !peerConnection.remoteDescription || !state.call.pendingRemoteCandidates.length) {
      return;
    }
    const queue = state.call.pendingRemoteCandidates.slice();
    state.call.pendingRemoteCandidates = [];
    for (const candidate of queue) {
      try {
        await peerConnection.addIceCandidate(candidate);
        appendCallDebug(`ice.flush ${candidate.sdpMid || "0"}/${candidate.sdpMLineIndex ?? -1}`);
      } catch (error) {
        // keep going; later candidates may still work
        appendCallDebug(`ice.flush_error ${String(error?.message || error)}`);
      }
    }
  }

  async function handleCallEvent(event, expectedCallId) {
    if (!state.call.current || !idsEqualSafe(state.call.current.id, expectedCallId)) {
      return;
    }
    const senderId = event?.senderID;
    const localSender = senderId && idsEqualSafe(senderId, state.user?.id);
    const eventType = String(event?.type || "");

    if ((eventType === "offer" || eventType === "answer" || eventType === "ice" || eventType === "media_state") && localSender) {
      return;
    }

    switch (eventType) {
      case "accepted":
        appendCallDebug(`event.accepted seq=${event.sequence || 0}`);
        applyCurrentCallSnapshot({
          ...state.call.current,
          state: "active",
          answeredAt: state.call.current.answeredAt || event.createdAt,
        });
        if (state.call.initiatedLocally && !state.call.offerSent) {
          void sendInitialOfferForCurrentCall("accepted_event");
        }
        if (state.call.initiatedLocally && state.call.requestedVideoStart) {
          window.setTimeout(() => {
            if (state.call.current && state.call.requestedVideoStart) {
              void ensureLocalVideoTrack();
            }
          }, 350);
        }
        if (state.call.acceptedLocally) {
          void maybeAnswerCurrentCall("accepted_event");
        }
        break;
      case "offer":
        if (event.sdp) {
          appendCallDebug(`event.offer seq=${event.sequence || 0} size=${String(event.sdp || "").length}`);
          state.call.pendingRemoteOfferSDP = normalizeSDP(event.sdp);
          if (callDirection(state.call.current) === "incoming" && state.call.acceptedLocally) {
            void maybeAnswerCurrentCall("offer_event");
          }
        }
        break;
      case "answer":
        if (event.sdp) {
          appendCallDebug(`event.answer seq=${event.sequence || 0} size=${String(event.sdp || "").length}`);
          await applyRemoteAnswerToCurrentCall(event.sdp);
        }
        break;
      case "ice":
        if (event.candidate) {
          appendCallDebug(`event.ice seq=${event.sequence || 0}`);
          await queueOrApplyRemoteIceCandidate(event);
        }
        break;
      case "media_state":
        if (typeof event.isMuted === "boolean") {
          state.call.remoteMuted = event.isMuted;
        }
        if (typeof event.isVideoEnabled === "boolean") {
          state.call.remoteVideoEnabled = event.isVideoEnabled;
        }
        renderCallOverlay();
        break;
      case "rejected":
        applyCurrentCallSnapshot({
          ...state.call.current,
          state: "rejected",
          endedAt: event.createdAt || new Date().toISOString(),
        });
        teardownCurrentCall({ preserveStatus: false });
        break;
      case "ended":
        applyCurrentCallSnapshot({
          ...state.call.current,
          state: "ended",
          endedAt: event.createdAt || new Date().toISOString(),
        });
        teardownCurrentCall({ preserveStatus: false });
        break;
      default:
        break;
    }
  }

  function teardownCurrentCall(options = {}) {
    stopCallEventPolling();
    clearCallDurationTicker();

    if (state.call.peerConnection) {
      try {
        state.call.peerConnection.onicecandidate = null;
        state.call.peerConnection.ontrack = null;
        state.call.peerConnection.close();
      } catch (error) {
        // ignore
      }
    }

    if (state.call.localStream && state.call.localStream !== options.preserveLocalStream) {
      state.call.localStream.getTracks().forEach((track) => track.stop());
    }
    if (state.call.remoteStream) {
      state.call.remoteStream.getTracks().forEach((track) => track.stop());
    }

    dom.callRemoteAudio.srcObject = null;
    dom.callLocalAudio.srcObject = null;
    dom.callRemoteVideo.srcObject = null;
    dom.callLocalVideo.srcObject = null;

    state.call.current = null;
    state.call.lastEventSequence = 0;
    state.call.peerConnection = null;
    state.call.localStream = null;
    state.call.remoteStream = null;
    state.call.iceServers = null;
    state.call.pendingRemoteCandidates = [];
    state.call.pendingRemoteOfferSDP = null;
    state.call.initiatedLocally = false;
    state.call.acceptedLocally = false;
    state.call.offerSent = false;
    state.call.answerSent = false;
    state.call.offerInFlight = false;
    state.call.answerInFlight = false;
    state.call.localOfferSDP = "";
    state.call.localAnswerSDP = "";
    state.call.localMuted = false;
    state.call.localVideoEnabled = false;
    state.call.localScreenShareEnabled = false;
    state.call.remoteMuted = false;
    state.call.remoteVideoEnabled = false;
    state.call.expanded = false;
    state.call.requestedVideoStart = false;
    state.call.availableDevices = {
      audioinput: [],
      videoinput: [],
      audiooutput: [],
    };
    state.call.selectedAudioInputId = "";
    state.call.selectedVideoInputId = "";
    state.call.selectedAudioOutputId = "";
    state.call.connectionLabel = "Idle";
    state.call.startedAtMs = 0;
    state.call.actionBusy = false;
    state.call.debugLines = [];
    if (!options.preserveStatus) {
      state.call.statusLine = "";
    }
    renderCallButton();
    renderCallOverlay();
  }

  function clearCallDurationTicker() {
    if (state.call.durationTicker) {
      window.clearInterval(state.call.durationTicker);
      state.call.durationTicker = null;
    }
  }

  function syncCallDurationTicker() {
    const current = state.call.current;
    if (!current || current.state !== "active" || !state.call.startedAtMs) {
      clearCallDurationTicker();
      return;
    }
    if (state.call.durationTicker) {
      return;
    }
    state.call.durationTicker = window.setInterval(() => {
      renderCallOverlay();
    }, 1000);
  }

  async function maybeOpenChatForCurrentCall() {
    const chatId = state.call.current?.chatID;
    if (!chatId || idsEqualSafe(state.activeChatId, chatId)) {
      return;
    }
    try {
      await openChat(chatId);
    } catch (error) {
      // ignore routing issues for now
    }
  }

  function setCallStatusLine(message) {
    state.call.statusLine = message || "";
    renderCallOverlay();
  }

  function appendCallDebug(line) {
    const text = String(line || "").trim();
    if (!text) {
      return;
    }
    const stamp = new Date().toLocaleTimeString([], {
      hour: "2-digit",
      minute: "2-digit",
      second: "2-digit",
    });
    state.call.debugLines.push(`${stamp} ${text}`);
    if (state.call.debugLines.length > 18) {
      state.call.debugLines = state.call.debugLines.slice(-18);
    }
    renderCallOverlay();
  }

  function renderCallButton() {
    const activeChat = getActiveChat();
    if (!activeChat || activeChat.type !== "direct" || activeChat.mode !== "online" || !otherParticipant(activeChat)?.id) {
      dom.callButton.classList.add("hidden");
      dom.videoCallButton.classList.add("hidden");
      dom.callButton.disabled = true;
      dom.videoCallButton.disabled = true;
      dom.callButton.textContent = "Call";
      dom.videoCallButton.textContent = "Video";
      return;
    }

    if (state.call.current && !idsEqualSafe(state.call.current.chatID, activeChat.id)) {
      dom.callButton.classList.add("hidden");
      dom.videoCallButton.classList.add("hidden");
      dom.callButton.disabled = true;
      dom.videoCallButton.disabled = true;
      return;
    }

    dom.callButton.classList.remove("hidden");
    dom.videoCallButton.classList.remove("hidden");
    dom.callButton.disabled = Boolean(state.call.actionBusy);
    dom.videoCallButton.disabled = Boolean(state.call.actionBusy);

    if (!state.call.current) {
      dom.callButton.textContent = "Call";
      dom.videoCallButton.textContent = "Video";
      return;
    }

    if (callDirection(state.call.current) === "incoming" && state.call.current.state === "ringing") {
      dom.callButton.textContent = "Decline";
      dom.videoCallButton.textContent = String(state.call.current.kind || "audio").toLowerCase() === "video" ? "Answer video" : "Video";
      return;
    }

    dom.callButton.textContent = "Hang up";
    dom.videoCallButton.textContent = String(state.call.current.kind || "audio").toLowerCase() === "video" ? "Video live" : "Video";
  }

  function renderCallOverlay() {
    const current = state.call.current;
    if (!current) {
      dom.callOverlay.classList.add("hidden");
      dom.callStatusLine.textContent = "";
      return;
    }

    const direction = callDirection(current);
    const participant = otherParticipantForCall(current);
    const isVideoCall = String(current.kind || "audio").toLowerCase() === "video";
    const canScreenShare = Boolean(navigator.mediaDevices?.getDisplayMedia);
    dom.callOverlay.classList.remove("hidden");
    dom.callOverlay.classList.toggle("is-expanded", Boolean(state.call.expanded));
    dom.callDirectionPill.textContent = direction === "incoming" ? `Incoming ${isVideoCall ? "video" : "audio"} call` : `${isVideoCall ? "Video" : "Audio"} call`;
    renderAvatar(
      dom.callAvatar,
      participant?.displayName || participant?.username || "Prime user",
      participant?.profilePhotoURL || null,
    );
    dom.callPeerName.textContent = participant?.displayName || participant?.username || "Prime user";
    dom.callStatusText.textContent = buildCallStatusText(current, direction);
    dom.callConnectionPill.textContent = state.call.connectionLabel || "Idle";
    dom.callLocalMutedPill.textContent = state.call.localMuted ? "Mic off" : "Mic on";
    dom.callLocalVideoPill.classList.toggle("hidden", !isVideoCall && !state.call.localVideoEnabled && !state.call.localScreenShareEnabled);
    dom.callLocalVideoPill.textContent = state.call.localScreenShareEnabled ? "Screen on" : state.call.localVideoEnabled ? "Camera on" : "Camera off";
    dom.callRemoteMutedPill.classList.toggle("hidden", !state.call.remoteMuted);
    dom.callRemoteVideoPill.classList.toggle("hidden", !isVideoCall);
    dom.callRemoteVideoPill.textContent = state.call.remoteVideoEnabled ? "Remote camera on" : "Remote camera off";
    dom.callDuration.classList.toggle("hidden", !(current.state === "active" && state.call.startedAtMs));
    dom.callDebugToggleButton.classList.toggle("hidden", current.state !== "active");
    dom.callDebugToggleButton.textContent = state.call.showDebugPanel ? "Hide debug" : "Debug";
    dom.callExpandButton.textContent = state.call.expanded ? "Compact" : "Expand";
    dom.callDebug.classList.toggle("hidden", !state.call.showDebugPanel);
    dom.callStage.classList.toggle("hidden", !isVideoCall);
    dom.callStageEmpty.classList.toggle("hidden", state.call.remoteVideoEnabled);
    dom.callLocalVideo.classList.toggle("hidden", !state.call.localVideoEnabled && !state.call.localScreenShareEnabled);
    dom.callDeviceRow.classList.toggle("hidden", current.state !== "active");
    if (current.state === "active" && state.call.startedAtMs) {
      dom.callDuration.textContent = formatDuration(Math.max(0, (Date.now() - state.call.startedAtMs) / 1000));
    }

    const incomingRinging = direction === "incoming" && current.state === "ringing";
    const showMute = current.state === "active";
    const showVideoToggle = current.state === "active" || (incomingRinging && isVideoCall);
    const showScreenShare = current.state === "active" && isVideoCall && canScreenShare;
    const showHangup = current.state === "active" || direction === "outgoing";

    dom.callRejectButton.classList.toggle("hidden", !incomingRinging);
    dom.callAnswerButton.classList.toggle("hidden", !incomingRinging);
    dom.callMuteButton.classList.toggle("hidden", !showMute);
    dom.callVideoToggleButton.classList.toggle("hidden", !showVideoToggle);
    dom.callScreenShareButton.classList.toggle("hidden", !showScreenShare);
    dom.callHangupButton.classList.toggle("hidden", !showHangup);
    dom.callAnswerButton.disabled = Boolean(state.call.actionBusy);
    dom.callRejectButton.disabled = Boolean(state.call.actionBusy);
    dom.callMuteButton.disabled = Boolean(state.call.actionBusy);
    dom.callVideoToggleButton.disabled = Boolean(state.call.actionBusy);
    dom.callScreenShareButton.disabled = Boolean(state.call.actionBusy);
    dom.callHangupButton.disabled = Boolean(state.call.actionBusy);
    dom.callAnswerButton.textContent = isVideoCall ? "Answer video" : "Answer";
    dom.callMuteButton.textContent = state.call.localMuted ? "Unmute" : "Mute";
    dom.callVideoToggleButton.textContent = state.call.localVideoEnabled || state.call.localScreenShareEnabled ? "Stop camera" : "Start camera";
    dom.callScreenShareButton.textContent = state.call.localScreenShareEnabled ? "Stop share" : "Share screen";
    dom.callStatusLine.textContent = state.call.statusLine || "";
    dom.callDebug.innerHTML = buildCallDebugLines(current);
    renderCallDeviceOptions();
  }

  function buildCallDebugLines(call) {
    const peerConnection = state.call.peerConnection;
    const summary = [
      `call=${call.id || "n/a"} state=${call.state || "n/a"} dir=${callDirection(call)}`,
      `kind=${call.kind || "audio"} localVideo=${state.call.localVideoEnabled} remoteVideo=${state.call.remoteVideoEnabled} share=${state.call.localScreenShareEnabled}`,
      `signaling=${peerConnection?.signalingState || "none"} conn=${peerConnection?.connectionState || "none"} ice=${peerConnection?.iceConnectionState || "none"}`,
      `offerSent=${state.call.offerSent} answerSent=${state.call.answerSent} localMuted=${state.call.localMuted} remoteMuted=${state.call.remoteMuted}`,
      `queuedICE=${state.call.pendingRemoteCandidates.length} lastSeq=${state.call.lastEventSequence || 0}`,
    ];
    return summary.concat(state.call.debugLines || []).map((line) => `<div>${escapeHtml(line)}</div>`).join("");
  }

  function buildCallStatusText(call, direction) {
    const stateValue = String(call?.state || "ringing");
    if (stateValue === "ringing") {
      return direction === "incoming"
        ? `Someone is calling you${String(call?.kind || "audio").toLowerCase() === "video" ? " with video" : ""} in Prime Messaging Web.`
        : `Calling… waiting for the other side to answer${String(call?.kind || "audio").toLowerCase() === "video" ? " and unlock video" : ""}.`;
    }
    if (stateValue === "active") {
      return state.call.connectionLabel === "Connected"
        ? `The ${String(call?.kind || "audio").toLowerCase()} call is live.`
        : "The call is active. Finishing the browser connection…";
    }
    if (stateValue === "rejected") {
      return "The call was declined.";
    }
    if (stateValue === "cancelled") {
      return "The call was cancelled.";
    }
    return "The call has ended.";
  }

  function callDirection(call) {
    if (!call || !state.user?.id) {
      return "outgoing";
    }
    return idsEqualSafe(call.callerID, state.user.id) ? "outgoing" : "incoming";
  }

  function otherParticipantForCall(call) {
    if (!call || !Array.isArray(call.participants) || !state.user?.id) {
      return null;
    }
    return call.participants.find((participant) => !idsEqualSafe(participant.id, state.user.id)) || call.participants[0] || null;
  }

  function isCallActiveState(value) {
    return value === "ringing" || value === "active";
  }

  function safePlayMediaElement(element) {
    if (!element) {
      return;
    }
    const playPromise = element.play?.();
    if (playPromise && typeof playPromise.catch === "function") {
      playPromise.catch(() => {});
    }
  }

  function handleRealtimeEvent(payload) {
    if (payload && typeof payload.seq === "number") {
      state.lastRealtimeSeq = Math.max(state.lastRealtimeSeq, payload.seq);
      persistSession();
    }

    const eventType = String(payload?.type || "");
    if (payload?.presence?.userID) {
      state.presenceByUserId.set(payload.presence.userID, payload.presence);
    }

    if (eventType === "message.created" || eventType === "message.updated" || eventType === "message.deleted") {
      if (payload.message && payload.chatID) {
        upsertMessage(payload.chatID, payload.message);
      }
      if (payload.chat) {
        upsertChat(payload.chat);
      }
      if (payload.chatID === state.activeChatId) {
        renderConversation();
        const isOwn = payload.message && state.user && payload.message.senderID === state.user.id;
        if (isOwn) {
          lockConversationToBottom(payload.chatID);
        }
        scheduleScrollMessagesToBottom(isOwn || shouldKeepConversationAtBottom(payload.chatID) || isNearBottom(dom.messageList));
        if (!isOwn) {
          scheduleMarkActiveChatRead();
        }
      } else {
        renderSidebar();
      }
      return;
    }

    if (eventType === "chat.updated" || eventType === "chat.read") {
      if (payload.chat) {
        upsertChat(payload.chat);
      }
      renderAll();
      return;
    }

    if (eventType === "typing.started" || eventType === "typing.stopped") {
      if (payload.chatID && payload.actorUserID) {
        const key = `${payload.chatID}:${payload.actorUserID}`;
        if (eventType === "typing.started") {
          state.typingByChatId.set(key, {
            chatID: payload.chatID,
            actorUserID: payload.actorUserID,
          });
        } else {
          state.typingByChatId.delete(key);
        }
      }
      renderTypingLine();
      return;
    }

    if (eventType === "presence.updated") {
      renderConversationHeader();
      return;
    }

    if (eventType.startsWith("system.")) {
      return;
    }
  }

  function upsertChat(chat) {
    if (!chat || !chat.id) {
      return;
    }
    const existingIndex = state.chats.findIndex((item) => item.id === chat.id);
    if (existingIndex >= 0) {
      state.chats.splice(existingIndex, 1, chat);
    } else {
      state.chats.push(chat);
    }
    state.chats.sort(compareChats);
    if (!state.activeChatId) {
      state.activeChatId = chat.id;
    }
    renderSidebar();
    renderConversationHeader();
    if (state.groupModalOpen && idsEqualSafe(state.groupEditor.chatId, chat.id)) {
      populateGroupEditor(chat);
    }
  }

  function upsertMessage(chatId, message) {
    if (!chatId || !message) {
      return;
    }
    const messages = (state.messagesByChatId.get(chatId) || []).slice();
    const existingIndex = messages.findIndex(
      (item) =>
        item.id === message.id ||
        (message.clientMessageID && item.clientMessageID === message.clientMessageID),
    );
    if (existingIndex >= 0) {
      messages.splice(existingIndex, 1, message);
    } else {
      messages.push(message);
    }
    messages.sort(compareMessages);
    state.messagesByChatId.set(chatId, messages);
  }

  async function serializeQueuedAttachment(item) {
    const base64 = await fileToBase64(item.file);
    return {
      file_name: item.file.name,
      mime_type: item.file.type || "application/octet-stream",
      type: item.attachmentType,
      data_base64: base64,
      byte_size: item.file.size,
    };
  }

  async function serializeQueuedVoiceMessage(item) {
    const base64 = await fileToBase64(item.blob);
    return {
      file_name: `voice-${createClientId()}.${mimeTypeExtension(item.mimeType)}`,
      mime_type: item.mimeType || "audio/webm",
      data_base64: base64,
      byte_size: item.blob.size,
      duration_seconds: item.durationSeconds || 0,
      waveform_samples: Array.isArray(item.waveformSamples) ? item.waveformSamples : [],
    };
  }

  async function request(path, options = {}) {
    const {
      method = "GET",
      body,
      auth = true,
      headers = {},
      signal,
      retrying = false,
    } = options;

    const url = `${state.apiBase.replace(/\/+$/, "")}${path.startsWith("/") ? path : `/${path}`}`;
    const requestHeaders = {
      "Content-Type": "application/json",
      "X-Prime-Platform": "web",
      "X-Prime-Device-ID": state.deviceId || getOrCreateWebDeviceId(),
      "X-Prime-Device-Name": "Prime Messaging Web",
      "X-Prime-Device-Model": navigator.userAgent || "browser",
      "X-Prime-App-Version": "web-0.1.0",
      ...headers,
    };

    if (auth && state.session?.accessToken) {
      requestHeaders.Authorization = `Bearer ${state.session.accessToken}`;
    }

    const response = await fetch(url, {
      method,
      headers: requestHeaders,
      body: body === undefined ? undefined : JSON.stringify(body),
      signal,
    });

    let payload = null;
    const text = await response.text();
    if (text) {
      try {
        payload = JSON.parse(text);
      } catch (error) {
        payload = { raw: text };
      }
    }

    if (response.status === 401 && auth && !retrying && state.session?.refreshToken) {
      const refreshed = await refreshSession();
      if (refreshed) {
        return request(path, { ...options, retrying: true });
      }
    }

    if (!response.ok) {
      const error = new Error((payload && payload.error) || `http_${response.status}`);
      error.status = response.status;
      error.payload = payload;
      throw error;
    }

    return payload;
  }

  async function refreshSession() {
    if (!state.session?.refreshToken) {
      return false;
    }
    try {
      const payload = await request("/auth/refresh", {
        method: "POST",
        auth: false,
        body: {
          refresh_token: state.session.refreshToken,
        },
      });
      applySessionPayload(payload);
      connectRealtime();
      return true;
    } catch (error) {
      return false;
    }
  }

  function applySessionPayload(payload) {
    if (!payload?.session?.access_token || !payload?.session?.refresh_token) {
      throw new Error("invalid_session_payload");
    }
    state.session = {
      accessToken: payload.session.access_token,
      refreshToken: payload.session.refresh_token,
      accessTokenExpiresAt: payload.session.access_token_expires_at,
      refreshTokenExpiresAt: payload.session.refresh_token_expires_at,
    };
    state.user = payload.user || state.user;
    persistSession();
  }

  function showAuthScreen() {
    dom.authScreen.classList.remove("hidden");
    dom.clientScreen.classList.add("hidden");
  }

  function showClientScreen() {
    dom.authScreen.classList.add("hidden");
    dom.clientScreen.classList.remove("hidden");
  }

  function toggleLoginBusy(isBusy) {
    dom.loginSubmit.disabled = isBusy;
    dom.loginIdentifier.disabled = isBusy;
    dom.loginPassword.disabled = isBusy;
    dom.apiBaseInput.disabled = isBusy;
  }

  function setAuthStatus(message) {
    dom.authStatus.textContent = message || "";
  }

  function setComposerStatus(message) {
    dom.composerStatus.textContent = message || "";
  }

  function setConnectionState(stateName) {
    dom.connectionPill.textContent = stateName === "online" ? "Realtime on" : stateName === "connecting" ? "Connecting" : "Offline";
    dom.connectionPill.classList.remove("online", "connecting");
    if (stateName === "online") {
      dom.connectionPill.classList.add("online");
    } else if (stateName === "connecting") {
      dom.connectionPill.classList.add("connecting");
    }
  }

  function renderAll() {
    renderMeCard();
    renderSearchResults();
    renderSidebar();
    renderConversationScaffold();
    renderCallOverlay();
  }

  function renderMeCard() {
    if (!state.user) {
      return;
    }
    const profile = state.user.profile || {};
    renderAvatar(dom.meAvatar, profile.displayName || profile.username || "PM", profile.profilePhotoURL);
    dom.meName.textContent = profile.displayName || "Prime Messaging user";
    dom.meHandle.textContent = profile.username ? `@${profile.username}` : "No username";
  }

  function renderSidebar() {
    const query = dom.globalSearch.value.trim().toLowerCase();
    const filteredChats = state.chats.filter((chat) => {
      if (!query) {
        return true;
      }
      return [chat.title, chat.subtitle, chat.lastMessagePreview]
        .filter(Boolean)
        .some((value) => String(value).toLowerCase().includes(query));
    });

    dom.chatList.innerHTML = "";

    if (!filteredChats.length) {
      const empty = document.createElement("div");
      empty.className = "empty-list";
      empty.textContent = query ? "No chats match this search yet." : "No online chats yet.";
      dom.chatList.appendChild(empty);
      return;
    }

    filteredChats.forEach((chat) => {
      const button = document.createElement("button");
      button.type = "button";
      button.className = `chat-item ${chat.id === state.activeChatId ? "active" : ""}`;
      button.setAttribute("data-chat-id", chat.id);
      button.innerHTML = `
        <div class="chat-item-row">
          ${avatarHtml(chatAvatarLabel(chat), chatAvatarUrl(chat), false)}
          <div class="chat-item-main">
            <div class="chat-item-title-row">
              <span class="chat-item-title">${escapeHtml(chat.title || "Untitled chat")}</span>
              <span class="chat-item-subtitle">${escapeHtml(formatTime(chat.lastActivityAt))}</span>
            </div>
            <div class="chat-item-preview">${escapeHtml(chat.lastMessagePreview || chat.subtitle || "No messages yet")}</div>
          </div>
          ${Number(chat.unreadCount || 0) > 0 ? `<span class="unread-badge">${Number(chat.unreadCount)}</span>` : ""}
        </div>
      `;
      button.addEventListener("click", () => openChat(chat.id));
      dom.chatList.appendChild(button);
    });
  }

  function renderSearchResults() {
    const query = dom.globalSearch.value.trim();
    const shouldShow = query.length >= 2;
    dom.searchResultsWrap.classList.toggle("hidden", !shouldShow);
    dom.searchResults.innerHTML = "";

    if (!shouldShow) {
      return;
    }

    if (!state.searchResults.length) {
      const empty = document.createElement("div");
      empty.className = "empty-list";
      empty.textContent = "No people found for this query.";
      dom.searchResults.appendChild(empty);
      return;
    }

    state.searchResults.forEach((user) => {
      const profile = user.profile || {};
      const button = document.createElement("button");
      button.type = "button";
      button.className = "search-result-item";
      button.setAttribute("data-start-chat-user-id", user.id);
      button.innerHTML = `
        <div class="chat-item-row">
          ${avatarHtml(profile.displayName || profile.username || "User", profile.profilePhotoURL, false)}
          <div class="chat-item-main">
            <div class="chat-item-title">${escapeHtml(profile.displayName || "Prime user")}</div>
            <div class="chat-item-preview">${escapeHtml(profile.username ? `@${profile.username}` : profile.email || "Open direct chat")}</div>
          </div>
        </div>
      `;
      button.addEventListener("click", () => startDirectChat(user.id));
      dom.searchResults.appendChild(button);
    });
  }

  function renderConversationScaffold() {
    const activeChat = getActiveChat();
    const hasChat = Boolean(activeChat);
    dom.conversationEmpty.classList.toggle("hidden", hasChat);
    dom.conversationBody.classList.toggle("hidden", !hasChat);
    if (!hasChat) {
      dom.chatTitle.textContent = "Select a chat";
      dom.chatSubtitle.textContent = "Your messages will appear here.";
      dom.chatModePill.textContent = "online";
      renderAvatar(dom.chatAvatar, "PM", null);
      dom.callButton.classList.add("hidden");
      dom.groupDetailsButton.classList.add("hidden");
      return;
    }
    renderConversationHeader();
    renderConversation();
  }

  function renderConversationHeader() {
    const activeChat = getActiveChat();
    if (!activeChat) {
      return;
    }

    renderAvatar(dom.chatAvatar, chatAvatarLabel(activeChat), chatAvatarUrl(activeChat));
    dom.chatTitle.textContent = activeChat.title || "Untitled chat";
    dom.chatSubtitle.textContent = buildChatSubtitle(activeChat);
    dom.chatModePill.textContent = activeChat.mode || "online";
    const showDetails = isGroupChat(activeChat);
    dom.groupDetailsButton.classList.toggle("hidden", !showDetails);
    if (showDetails) {
      dom.groupDetailsButton.textContent = groupKindLabel(normalizedGroupKind(activeChat));
    }
    renderCallButton();
  }

  function renderConversation() {
    const activeChat = getActiveChat();
    if (!activeChat) {
      return;
    }

    const messages = state.messagesByChatId.get(activeChat.id) || [];
    dom.messageList.innerHTML = "";

    if (!messages.length) {
      const empty = document.createElement("div");
      empty.className = "empty-list";
      empty.textContent = "No messages yet. Start the conversation.";
      dom.messageList.appendChild(empty);
    } else {
      messages.forEach((message) => {
        dom.messageList.appendChild(renderMessageCard(activeChat, message));
      });
    }

    renderTypingLine();
    renderQueuedAttachments();
    renderReplyBanner();
    renderEditBanner();
    renderVoiceDraft();
    renderDropZone(state.dragDepth > 0);
    updateRecordButton();
    bindConversationMediaAutoScroll(activeChat.id);
  }

  function renderMessageCard(chat, message) {
    const isOwn = state.user && message.senderID === state.user.id;
    const card = document.createElement("article");
    card.className = `message-card ${isOwn ? "own" : ""}`;
    card.setAttribute("data-message-card-id", message.id);

    const deleted = Boolean(message.deletedForEveryoneAt);
    const textHtml = deleted
      ? `<div class="message-text deleted">Message deleted</div>`
      : message.text
        ? `<div class="message-text">${formatText(message.text)}</div>`
        : "";

    card.innerHTML = `
      <div class="message-topline">
        <span class="message-sender">${escapeHtml(isOwn ? "You" : message.senderDisplayName || "Prime user")}</span>
        <span class="message-meta">${escapeHtml(formatDateTime(message.createdAt))}${message.editedAt ? " · edited" : ""}</span>
      </div>
      ${message.replyPreview ? renderReplyPreview(message.replyPreview) : ""}
      ${textHtml}
      ${renderAttachments(message)}
      ${renderVoiceMessage(message.voiceMessage)}
      <div class="message-footer">
        <div class="reaction-row">
          ${renderReactions(message)}
        </div>
        <div class="message-actions">
          ${renderReactionButtons(message)}
          ${renderMessageActions(message, isOwn)}
        </div>
      </div>
    `;
    return card;
  }

  function renderReplyPreview(replyPreview) {
    return `
      <div class="message-reply">
        <strong>${escapeHtml(replyPreview.senderDisplayName || "Reply")}</strong>
        <div>${escapeHtml(replyPreview.previewText || "")}</div>
      </div>
    `;
  }

  function renderAttachments(message) {
    if (!Array.isArray(message.attachments) || !message.attachments.length) {
      return "";
    }
    return `
      <div class="attachment-grid">
        ${message.attachments.map((attachment) => renderAttachment(attachment)).join("")}
      </div>
    `;
  }

  function renderAttachment(attachment) {
    const type = String(attachment.type || "document").toLowerCase();
    const url = safeUrl(attachment.remoteURL);
    const escapedUrl = url ? escapeHtml(url) : null;
    const fileName = escapeHtml(attachment.fileName || "Attachment");
    const size = formatBytes(attachment.byteSize || 0);

    if (type === "image" && url) {
      return `
        <a class="message-attachment" href="${escapedUrl}" target="_blank" rel="noreferrer">
          <img src="${escapedUrl}" alt="${fileName}" loading="lazy" />
          <div class="message-attachment-copy">
            <strong>${fileName}</strong>
            <span class="message-attachment-meta">${size}</span>
          </div>
        </a>
      `;
    }

    if (type === "video" && url) {
      return `
        <div class="message-attachment">
          <video src="${escapedUrl}" controls preload="metadata"></video>
          <div class="message-attachment-copy">
            <strong>${fileName}</strong>
            <span class="message-attachment-meta">${size}</span>
          </div>
        </div>
      `;
    }

    if (type === "audio" && url) {
      return `
        <div class="message-attachment">
          <audio src="${escapedUrl}" controls preload="metadata"></audio>
          <div class="message-attachment-copy">
            <strong>${fileName}</strong>
            <span class="message-attachment-meta">${size}</span>
          </div>
        </div>
      `;
    }

    return `
      <a class="message-attachment" href="${escapedUrl || "#"}" ${url ? 'target="_blank" rel="noreferrer"' : ""}>
        <div class="message-attachment-copy">
          <strong>${fileName}</strong>
          <span class="message-attachment-meta">${escapeHtml(type)} · ${size}</span>
        </div>
      </a>
    `;
  }

  function renderVoiceMessage(voiceMessage) {
    if (!voiceMessage || !safeUrl(voiceMessage.remoteFileURL)) {
      return "";
    }
    const url = escapeHtml(safeUrl(voiceMessage.remoteFileURL));
    return `
      <div class="message-attachment">
        <audio src="${url}" controls preload="metadata"></audio>
        <div class="message-attachment-copy">
          <strong>Voice message</strong>
          <span class="message-attachment-meta">${escapeHtml(String(voiceMessage.durationSeconds || 0))} sec</span>
        </div>
      </div>
    `;
  }

  function renderReactions(message) {
    if (!Array.isArray(message.reactions) || !message.reactions.length) {
      return "";
    }
    return message.reactions
      .map((reaction) => {
        const isActive = state.user && Array.isArray(reaction.userIDs) && reaction.userIDs.includes(state.user.id);
        const count = Array.isArray(reaction.userIDs) ? reaction.userIDs.length : 0;
        return `<button class="reaction-chip ${isActive ? "active" : ""}" type="button" data-message-id="${escapeHtml(message.id)}" data-reaction-emoji="${escapeHtml(reaction.emoji || "")}">${escapeHtml(reaction.emoji || "")} ${count}</button>`;
      })
      .join("");
  }

  function renderReactionButtons(message) {
    if (message.deletedForEveryoneAt) {
      return "";
    }
    return DEFAULT_REACTIONS.map(
      (emoji) =>
        `<button class="message-action-button" type="button" data-message-id="${escapeHtml(message.id)}" data-reaction-emoji="${escapeHtml(emoji)}">${escapeHtml(emoji)}</button>`,
    ).join("");
  }

  function renderMessageActions(message, isOwn) {
    if (message.deletedForEveryoneAt) {
      return "";
    }
    const replyButton = `<button class="message-action-button" type="button" data-message-id="${escapeHtml(message.id)}" data-message-action="reply">Reply</button>`;
    if (!isOwn) {
      return replyButton;
    }
    const canEdit = !message.attachments?.length && !message.voiceMessage && message.text;
    return `
      ${replyButton}
      ${canEdit ? `<button class="message-action-button" type="button" data-message-id="${escapeHtml(message.id)}" data-message-action="edit">Edit</button>` : ""}
      <button class="message-action-button" type="button" data-message-id="${escapeHtml(message.id)}" data-message-action="delete">Delete</button>
    `;
  }

  function renderReplyBanner() {
    const isReplying = Boolean(state.replyingToMessageId && state.replyingToPreview);
    dom.replyBanner.classList.toggle("hidden", !isReplying);
    if (!isReplying) {
      dom.replyBannerTitle.textContent = "Replying";
      dom.replyBannerText.textContent = "";
      return;
    }
    dom.replyBannerTitle.textContent = `Replying to ${state.replyingToPreview.senderDisplayName || "Prime user"}`;
    dom.replyBannerText.textContent = state.replyingToPreview.previewText || "Message";
  }

  function renderTypingLine() {
    const activeChat = getActiveChat();
    if (!activeChat) {
      dom.typingLine.textContent = "";
      return;
    }

    const typingParticipants = [];
    for (const entry of state.typingByChatId.values()) {
      if (entry.chatID !== activeChat.id) {
        continue;
      }
      if (state.user && entry.actorUserID === state.user.id) {
        continue;
      }
      typingParticipants.push(entry.actorUserID);
    }

    if (typingParticipants.length) {
      const names = typingParticipants
        .map((userId) => participantNameForChat(activeChat, userId))
        .filter(Boolean);
      dom.typingLine.textContent = `${names.join(", ")} ${names.length > 1 ? "are" : "is"} typing…`;
      return;
    }

    dom.typingLine.textContent = "";
  }

  function renderQueuedAttachments() {
    dom.attachmentStrip.classList.toggle("hidden", state.queuedAttachments.length === 0);
    dom.attachmentStrip.innerHTML = "";
    state.queuedAttachments.forEach((item) => {
      const chip = document.createElement("div");
      chip.className = "attachment-chip";
      chip.innerHTML = `
        <div class="attachment-chip-preview">${renderAttachmentPreview(item)}</div>
        <div class="attachment-chip-copy">
          <strong>${escapeHtml(item.file.name)}</strong>
          <span class="message-attachment-meta">${escapeHtml(item.attachmentType)} · ${escapeHtml(formatBytes(item.file.size))}</span>
        </div>
        <button class="attachment-chip-remove" type="button" data-remove-attachment-id="${escapeHtml(item.id)}">×</button>
      `;
      chip.querySelector("[data-remove-attachment-id]").addEventListener("click", () => removeQueuedAttachment(item.id));
      dom.attachmentStrip.appendChild(chip);
    });
  }

  function renderVoiceDraft() {
    const shouldShow = state.isRecordingVoice || Boolean(state.queuedVoiceMessage);
    dom.voiceBanner.classList.toggle("hidden", !shouldShow);
    if (!shouldShow) {
      resetVoicePreview();
      return;
    }

    if (state.isRecordingVoice) {
      dom.voiceBannerTitle.textContent = "Recording voice message";
      dom.voiceBannerText.textContent = `${formatDuration(Math.max(1, Math.round((Date.now() - state.voiceRecordingStartedAt) / 1000)))} · Click Stop when ready`;
      dom.removeVoiceButton.textContent = "Cancel";
      resetVoicePreview();
      return;
    }

    dom.voiceBannerTitle.textContent = "Voice message ready";
    dom.voiceBannerText.textContent = `${formatDuration(state.queuedVoiceMessage.durationSeconds)} · ${formatBytes(state.queuedVoiceMessage.blob.size)}`;
    dom.removeVoiceButton.textContent = "Remove";
    if (dom.voicePreview.src !== state.queuedVoiceMessage.previewUrl) {
      dom.voicePreview.src = state.queuedVoiceMessage.previewUrl;
    }
    dom.voicePreview.classList.remove("hidden");
  }

  function resetVoicePreview() {
    const hadSource = Boolean(dom.voicePreview.getAttribute("src"));
    dom.voicePreview.classList.add("hidden");
    if (hadSource) {
      dom.voicePreview.removeAttribute("src");
      dom.voicePreview.load();
    }
  }

  function renderDropZone(isVisible) {
    dom.dropZone.classList.toggle("hidden", !isVisible);
    dom.composerWrap.classList.toggle("drag-active", isVisible);
  }

  function updateRecordButton() {
    dom.recordButton.textContent = state.isRecordingVoice ? "Stop" : "Mic";
    dom.recordButton.classList.toggle("recording", state.isRecordingVoice);
  }

  function renderAttachmentPreview(item) {
    if (item.previewUrl && item.file.type.startsWith("image/")) {
      return `<img src="${escapeHtml(item.previewUrl)}" alt="${escapeHtml(item.file.name)}" />`;
    }
    if (item.previewUrl && item.file.type.startsWith("video/")) {
      return `<video src="${escapeHtml(item.previewUrl)}" muted></video>`;
    }
    return `<span>${escapeHtml(item.attachmentType.slice(0, 1).toUpperCase())}</span>`;
  }

  function renderEditBanner() {
    const isEditing = Boolean(state.editingMessageId);
    dom.editBanner.classList.toggle("hidden", !isEditing);
    if (!isEditing) {
      return;
    }
    dom.editBannerText.textContent = state.editingOriginalText || "";
  }

  function renderAvatar(target, label, imageUrl) {
    target.innerHTML = "";
    const url = safeUrl(imageUrl);
    if (url) {
      const image = document.createElement("img");
      image.src = url;
      image.alt = label || "Avatar";
      target.appendChild(image);
      return;
    }
    target.textContent = initials(label);
  }

  function avatarHtml(label, imageUrl, large) {
    const url = safeUrl(imageUrl);
    return `<span class="avatar ${large ? "avatar-large" : ""}">${url ? `<img src="${escapeHtml(url)}" alt="${escapeHtml(label || "Avatar")}" />` : escapeHtml(initials(label))}</span>`;
  }

  function chatAvatarLabel(chat) {
    if (!chat) {
      return "PM";
    }
    if (chat.title) {
      return chat.title;
    }
    const participant = otherParticipant(chat);
    return participant?.profile?.displayName || participant?.profile?.username || "PM";
  }

  function chatAvatarUrl(chat) {
    if (!chat) {
      return null;
    }
    if (chat.group?.photoURL) {
      return chat.group.photoURL;
    }
    const participant = otherParticipant(chat);
    return participant?.profile?.profilePhotoURL || null;
  }

  function otherParticipant(chat) {
    if (!chat || !Array.isArray(chat.participants) || !state.user) {
      return null;
    }
    return (
      chat.participants.find((participant) => participant.id !== state.user.id) ||
      chat.participants[0] ||
      null
    );
  }

  function buildChatSubtitle(chat) {
    const typingParticipants = [];
    for (const entry of state.typingByChatId.values()) {
      if (entry.chatID === chat.id && (!state.user || entry.actorUserID !== state.user.id)) {
        typingParticipants.push(participantNameForChat(chat, entry.actorUserID));
      }
    }
    if (typingParticipants.length) {
      return `${typingParticipants.join(", ")} ${typingParticipants.length > 1 ? "are" : "is"} typing…`;
    }

    if (chat.type === "direct") {
      const participant = otherParticipant(chat);
      if (participant) {
        const presence = state.presenceByUserId.get(participant.id);
        if (presence?.state === "online") {
          return "Online now";
        }
        if (presence?.state === "lastSeen" && presence.lastSeenAt) {
          return `Last seen ${formatDateTime(presence.lastSeenAt)}`;
        }
        if (chat.subtitle) {
          return chat.subtitle;
        }
      }
    }
    return chat.subtitle || `${chat.participantIDs?.length || 0} participants`;
  }

  function participantNameForChat(chat, userId) {
    const participant = (chat.participants || []).find((entry) => entry.id === userId);
    if (!participant) {
      return "Someone";
    }
    return participant.profile?.displayName || participant.profile?.username || "Prime user";
  }

  function getActiveChat() {
    return state.chats.find((chat) => chat.id === state.activeChatId) || null;
  }

  function onVisibilitySafeElement(element) {
    return element && !element.classList.contains("hidden");
  }

  function scrollMessagesToBottom(force) {
    if (!onVisibilitySafeElement(dom.conversationBody)) {
      return;
    }
    if (!force && !isNearBottom(dom.messageList)) {
      return;
    }
    dom.messageList.scrollTop = dom.messageList.scrollHeight;
  }

  function scheduleScrollMessagesToBottom(force) {
    const delays = [0, 40, 140, 320, 700];
    delays.forEach((delay) => {
      window.setTimeout(() => scrollMessagesToBottom(force), delay);
    });
  }

  function lockConversationToBottom(chatId) {
    state.bottomLockChatId = chatId;
    state.bottomLockExpiresAt = Date.now() + 1800;
  }

  function shouldKeepConversationAtBottom(chatId) {
    return Boolean(chatId) && state.bottomLockChatId === chatId && state.bottomLockExpiresAt > Date.now();
  }

  function bindConversationMediaAutoScroll(chatId) {
    dom.messageList.querySelectorAll("img, video").forEach((element) => {
      if (element.dataset.bottomLockBound === "1") {
        return;
      }
      element.dataset.bottomLockBound = "1";
      const eventName = element.tagName === "VIDEO" ? "loadedmetadata" : "load";
      element.addEventListener(
        eventName,
        () => {
          if (state.activeChatId !== chatId) {
            return;
          }
          if (shouldKeepConversationAtBottom(chatId) || isNearBottom(dom.messageList)) {
            scheduleScrollMessagesToBottom(true);
          }
        },
        { once: true },
      );
    });
  }

  function isNearBottom(element) {
    const remaining = element.scrollHeight - element.scrollTop - element.clientHeight;
    return remaining < 120;
  }

  function autoSizeComposer() {
    dom.composerInput.style.height = "auto";
    dom.composerInput.style.height = `${Math.min(dom.composerInput.scrollHeight, 200)}px`;
  }

  function createClientId() {
    if (window.crypto?.randomUUID) {
      return window.crypto.randomUUID();
    }
    return `web-${Date.now()}-${Math.random().toString(16).slice(2)}`;
  }

  function inferAttachmentType(file) {
    if (file.type.startsWith("image/")) {
      return "image";
    }
    if (file.type.startsWith("video/")) {
      return "video";
    }
    if (file.type.startsWith("audio/")) {
      return "audio";
    }
    return "document";
  }

  function fileToBase64(file) {
    return new Promise((resolve, reject) => {
      const reader = new FileReader();
      reader.onload = () => {
        const result = String(reader.result || "");
        const parts = result.split(",");
        resolve(parts[1] || "");
      };
      reader.onerror = () => reject(new Error("file_read_failed"));
      reader.readAsDataURL(file);
    });
  }

  function sleep(ms) {
    return new Promise((resolve) => window.setTimeout(resolve, Math.max(0, Number(ms || 0))));
  }

  function pickVoiceMimeType() {
    if (!window.MediaRecorder?.isTypeSupported) {
      return "";
    }
    const candidates = [
      "audio/webm;codecs=opus",
      "audio/ogg;codecs=opus",
      "audio/mp4",
      "audio/webm",
      "audio/ogg",
    ];
    return candidates.find((candidate) => window.MediaRecorder.isTypeSupported(candidate)) || "";
  }

  function mimeTypeExtension(mimeType) {
    const normalized = String(mimeType || "").toLowerCase();
    if (normalized.includes("mp4") || normalized.includes("aac") || normalized.includes("m4a")) {
      return "m4a";
    }
    if (normalized.includes("ogg")) {
      return "ogg";
    }
    if (normalized.includes("wav")) {
      return "wav";
    }
    return "webm";
  }

  function messagePreviewText(message) {
    if (!message) {
      return "Message";
    }
    if (message.deletedForEveryoneAt) {
      return "Deleted message";
    }
    if (message.text) {
      return message.text;
    }
    if (message.voiceMessage) {
      return "Voice message";
    }
    if (Array.isArray(message.attachments) && message.attachments.length) {
      const firstAttachment = message.attachments[0];
      const type = String(firstAttachment.type || "attachment").toLowerCase();
      if (type === "image") {
        return "Photo";
      }
      if (type === "video") {
        return "Video";
      }
      if (type === "audio") {
        return "Audio";
      }
      return firstAttachment.fileName || "Attachment";
    }
    return "Message";
  }

  function compareChats(left, right) {
    const leftTime = new Date(left.lastActivityAt || 0).getTime();
    const rightTime = new Date(right.lastActivityAt || 0).getTime();
    return rightTime - leftTime;
  }

  function compareMessages(left, right) {
    return new Date(left.createdAt || 0).getTime() - new Date(right.createdAt || 0).getTime();
  }

  function initials(value) {
    const words = String(value || "")
      .trim()
      .split(/\s+/)
      .filter(Boolean)
      .slice(0, 2);
    if (!words.length) {
      return "PM";
    }
    return words.map((word) => word[0]).join("").toUpperCase();
  }

  function escapeHtml(value) {
    return String(value ?? "")
      .replaceAll("&", "&amp;")
      .replaceAll("<", "&lt;")
      .replaceAll(">", "&gt;")
      .replaceAll('"', "&quot;")
      .replaceAll("'", "&#39;");
  }

  function formatText(value) {
    return escapeHtml(value).replace(/\n/g, "<br />");
  }

  function safeUrl(value) {
    const normalized = String(value || "").trim();
    if (!normalized) {
      return null;
    }
    if (normalized.startsWith("https://") || normalized.startsWith("http://")) {
      return normalized;
    }
    return null;
  }

  function idsEqualSafe(left, right) {
    return String(left || "").trim().toLowerCase() === String(right || "").trim().toLowerCase() && String(left || "").trim() !== "";
  }

  function normalizedApiBase(value) {
    const normalized = String(value || "").trim().replace(/\/+$/, "");
    if (!normalized) {
      return null;
    }
    if (!/^https?:\/\//i.test(normalized)) {
      return null;
    }
    return normalized;
  }

  function getOrCreateWebDeviceId() {
    try {
      const existing = localStorage.getItem(STORAGE_DEVICE_ID_KEY);
      if (existing) {
        return existing;
      }
      const created = createClientId();
      localStorage.setItem(STORAGE_DEVICE_ID_KEY, created);
      return created;
    } catch (error) {
      return createClientId();
    }
  }

  function toWebSocketBase(apiBase) {
    if (apiBase.startsWith("https://")) {
      return `wss://${apiBase.slice("https://".length)}`;
    }
    if (apiBase.startsWith("http://")) {
      return `ws://${apiBase.slice("http://".length)}`;
    }
    return apiBase;
  }

  function formatTime(value) {
    if (!value) {
      return "";
    }
    const date = new Date(value);
    return new Intl.DateTimeFormat(undefined, {
      hour: "2-digit",
      minute: "2-digit",
    }).format(date);
  }

  function formatDateTime(value) {
    if (!value) {
      return "";
    }
    const date = new Date(value);
    return new Intl.DateTimeFormat(undefined, {
      month: "short",
      day: "numeric",
      hour: "2-digit",
      minute: "2-digit",
    }).format(date);
  }

  function formatBytes(value) {
    const bytes = Number(value || 0);
    if (!Number.isFinite(bytes) || bytes <= 0) {
      return "0 B";
    }
    const units = ["B", "KB", "MB", "GB"];
    let size = bytes;
    let index = 0;
    while (size >= 1024 && index < units.length - 1) {
      size /= 1024;
      index += 1;
    }
    const rounded = size >= 10 || index === 0 ? Math.round(size) : size.toFixed(1);
    return `${rounded} ${units[index]}`;
  }

  function formatDuration(value) {
    const totalSeconds = Math.max(0, Math.round(Number(value || 0)));
    const minutes = Math.floor(totalSeconds / 60);
    const seconds = totalSeconds % 60;
    return `${minutes}:${String(seconds).padStart(2, "0")}`;
  }

  function humanizeAccountKind(value) {
    switch (String(value || "standard")) {
      case "offlineOnly":
        return "Offline-only account";
      case "guest":
        return "Guest account";
      default:
        return "Standard account";
    }
  }

  function humanizeApiError(error, fallbackMessage) {
    const code = String(error?.payload?.error || error?.message || "");
    switch (code) {
      case "browser_calling_unsupported":
        return "This browser does not support Prime Messaging calls yet.";
      case "microphone_permission_denied":
        return "Microphone access is required for browser calls.";
      case "invalid_credentials":
        return "The login details are incorrect.";
      case "user_not_found":
        return "No account was found for this login.";
      case "call_not_found":
        return "This call is no longer available.";
      case "call_permission_denied":
        return "You do not have permission to control this call.";
      case "call_requires_saved_contact":
        return "You can only call saved contacts from this account right now.";
      case "invalid_call_operation":
        return "That call action is not allowed in the current state.";
      case "invalid_remote_answer_state":
        return "The browser received the remote answer too early. Retrying the call setup can help.";
      case "invalid_media_state_payload":
        return "The browser could not sync the current mute state.";
      case "sender_not_in_chat":
        return "You do not have access to this chat.";
      case "chat_not_found":
        return "The chat could not be found.";
      case "message_not_found":
        return "The message no longer exists.";
      case "group_permission_denied":
        return "You do not have permission to manage this space.";
      case "invalid_group_operation":
        return "That group or channel action is not allowed right now.";
      case "group_invites_blocked":
        return "At least one person cannot be added because their invite settings block it.";
      case "join_approval_required":
        return "This public space requires join approval.";
      case "chat_not_public":
        return "This space does not accept public joins.";
      case "chat_admin_blocked":
        return "This space is currently blocked by moderation.";
      case "invalid_username":
        return "Choose a valid username.";
      case "username_taken":
        return "This username is already taken.";
      case "invalid_email":
        return "Enter a valid email address.";
      case "invalid_phone_number":
        return "Enter a valid phone number.";
      case "email_taken":
        return "This email is already used by another account.";
      case "phone_taken":
        return "This phone number is already used by another account.";
      case "empty_message":
        return "Message text cannot be empty.";
      case "guest_request_pending":
        return "This guest conversation still needs approval before messaging.";
      case "guest_request_approval_required":
        return "This conversation requires approval before messaging.";
      case "chat_mode_mismatch":
        return "This chat is not available in the selected mode.";
      case "current_password_required":
        return "Enter your current password to change it.";
      case "cannot_revoke_current_session":
        return "The current session cannot be revoked from this list.";
      case "guest_limited_profile":
        return "Guest accounts cannot change profile photos.";
      case "edit_not_allowed":
        return "This change is not allowed for the current account.";
      case "delete_not_allowed":
        return "This item cannot be removed right now.";
      case "user_banned":
        return "This user is banned from the space.";
      case "unsupported_media_type":
        return "This file type is not supported yet.";
      case "uploaded_media_not_found":
        return "The uploaded file could not be attached.";
      case "file_too_large":
        return "One of the selected files is too large.";
      default:
        return fallbackMessage;
    }
  }
})();
