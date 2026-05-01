(function () {
  const DEFAULT_API_BASE = "https://prime-messaging-production.up.railway.app";
  const ADMIN_USERNAME = "mihran";
  const STORAGE_SESSION_KEY = "prime-admin-console.session.v1";
  const STORAGE_CONFIG_KEY = "prime-admin-console.config.v1";
  const COMMUNITY_KINDS = ["group", "supergroup", "channel", "community"];

  const state = {
    apiBase: DEFAULT_API_BASE,
    session: null,
    authUser: null,
    connectionState: "idle",
    adminLogin: "admin",
    adminPassword: "",
    summary: null,
    appVersionPolicy: null,
    users: [],
    communities: [],
    selectedUser: null,
    selectedUserChats: [],
    selectedChat: null,
    selectedChatMessages: [],
    chatFocusUserId: null,
    communityFilter: "all",
    communitySearch: "",
    usersSearch: "",
    quickLookup: "",
    placeholdersOnly: false,
    usersDebounceTimer: null,
    status: {
      auth: "",
      access: "",
      maintenance: "",
      createUser: "",
      updatePolicy: "",
      users: "",
      selectedUser: "",
      communities: "",
      chat: "",
      broadcast: "",
    },
    busy: {
      auth: false,
      dashboard: false,
      access: false,
      createUser: false,
      updatePolicy: false,
      users: false,
      selectedUser: false,
      communities: false,
      chat: false,
      maintenance: false,
      broadcast: false,
    },
  };

  const dom = {};

  document.addEventListener("DOMContentLoaded", init);

  function init() {
    cacheDom();
    bindEvents();
    restoreConfig();
    restoreSession();
    hydrateAuthForm();
    hydrateAccessForm();
    renderAll();

    if (state.session) {
      setStatus("auth", "Restoring your admin session…");
      bootstrapAuthenticatedSession();
    }
  }

  function cacheDom() {
    dom.authScreen = document.getElementById("auth-screen");
    dom.appScreen = document.getElementById("app-screen");
    dom.loginForm = document.getElementById("login-form");
    dom.loginIdentifier = document.getElementById("login-identifier");
    dom.loginPassword = document.getElementById("login-password");
    dom.loginAdminLogin = document.getElementById("login-admin-login");
    dom.loginAdminPassword = document.getElementById("login-admin-password");
    dom.apiBaseInput = document.getElementById("api-base-input");
    dom.loginSubmit = document.getElementById("login-submit");
    dom.authStatus = document.getElementById("auth-status");

    dom.sessionName = document.getElementById("session-name");
    dom.sessionHandle = document.getElementById("session-handle");
    dom.refreshDashboardButton = document.getElementById("refresh-dashboard-button");
    dom.logoutButton = document.getElementById("logout-button");
    dom.connectionPill = document.getElementById("connection-pill");

    dom.accessForm = document.getElementById("access-form");
    dom.adminLoginInput = document.getElementById("admin-login-input");
    dom.adminPasswordInput = document.getElementById("admin-password-input");
    dom.saveAccessButton = document.getElementById("save-access-button");
    dom.accessStatus = document.getElementById("access-status");

    dom.summaryUsers = document.getElementById("summary-users");
    dom.summaryLegacyUsers = document.getElementById("summary-legacy-users");
    dom.summaryChats = document.getElementById("summary-chats");
    dom.summaryMessages = document.getElementById("summary-messages");
    dom.summarySessions = document.getElementById("summary-sessions");
    dom.summaryDeviceTokens = document.getElementById("summary-device-tokens");
    dom.cleanupLegacyButton = document.getElementById("cleanup-legacy-button");
    dom.bulkDeleteFilteredButton = document.getElementById("bulk-delete-filtered-button");
    dom.maintenanceStatus = document.getElementById("maintenance-status");

    dom.createUserForm = document.getElementById("create-user-form");
    dom.createDisplayNameInput = document.getElementById("create-display-name-input");
    dom.createUsernameInput = document.getElementById("create-username-input");
    dom.createPasswordInput = document.getElementById("create-password-input");
    dom.createUserButton = document.getElementById("create-user-button");
    dom.createUserStatus = document.getElementById("create-user-status");

    dom.appUpdatePolicyForm = document.getElementById("app-update-policy-form");
    dom.updateLatestVersionInput = document.getElementById("update-latest-version-input");
    dom.updateMinimumVersionInput = document.getElementById("update-minimum-version-input");
    dom.updateAppStoreURLInput = document.getElementById("update-app-store-url-input");
    dom.updateTitleInput = document.getElementById("update-title-input");
    dom.updateMessageInput = document.getElementById("update-message-input");
    dom.updateRequiredTitleInput = document.getElementById("update-required-title-input");
    dom.updateRequiredMessageInput = document.getElementById("update-required-message-input");
    dom.saveUpdatePolicyButton = document.getElementById("save-update-policy-button");
    dom.softPromptUpdateButton = document.getElementById("soft-prompt-update-button");
    dom.requireLatestUpdateButton = document.getElementById("require-latest-update-button");
    dom.resetUpdatePolicyButton = document.getElementById("reset-update-policy-button");
    dom.updatePolicyStatus = document.getElementById("update-policy-status");

    dom.usersRefreshButton = document.getElementById("users-refresh-button");
    dom.usersSearchInput = document.getElementById("users-search-input");
    dom.usersPlaceholdersOnlyInput = document.getElementById("users-placeholders-only-input");
    dom.userLookupForm = document.getElementById("user-lookup-form");
    dom.userLookupInput = document.getElementById("user-lookup-input");
    dom.userLookupButton = document.getElementById("user-lookup-button");
    dom.usersCount = document.getElementById("users-count");
    dom.usersFilterHint = document.getElementById("users-filter-hint");
    dom.usersStatus = document.getElementById("users-status");
    dom.usersList = document.getElementById("users-list");

    dom.selectedUserRefreshButton = document.getElementById("selected-user-refresh-button");
    dom.selectedUserEmpty = document.getElementById("selected-user-empty");
    dom.selectedUserContent = document.getElementById("selected-user-content");
    dom.selectedUserName = document.getElementById("selected-user-name");
    dom.selectedUserHandle = document.getElementById("selected-user-handle");
    dom.selectedUserTags = document.getElementById("selected-user-tags");
    dom.selectedUserChatCount = document.getElementById("selected-user-chat-count");
    dom.selectedUserMessageCount = document.getElementById("selected-user-message-count");
    dom.selectedUserSessionCount = document.getElementById("selected-user-session-count");
    dom.selectedUserMeta = document.getElementById("selected-user-meta");
    dom.selectedUserPremiumButton = document.getElementById("selected-user-premium-button");
    dom.deleteSelectedUserButton = document.getElementById("delete-selected-user-button");
    dom.selectedUserStatus = document.getElementById("selected-user-status");
    dom.selectedUserChatsCount = document.getElementById("selected-user-chats-count");
    dom.selectedUserChatsList = document.getElementById("selected-user-chats-list");

    dom.communitiesRefreshButton = document.getElementById("communities-refresh-button");
    dom.communitiesSearchInput = document.getElementById("communities-search-input");
    dom.communitiesFilterSelect = document.getElementById("communities-filter-select");
    dom.communitiesStatus = document.getElementById("communities-status");
    dom.communitiesList = document.getElementById("communities-list");

    dom.chatRefreshButton = document.getElementById("chat-refresh-button");
    dom.chatEmpty = document.getElementById("chat-empty");
    dom.chatContent = document.getElementById("chat-content");
    dom.chatPanelTitle = document.getElementById("chat-panel-title");
    dom.chatTitle = document.getElementById("chat-title");
    dom.chatSubtitle = document.getElementById("chat-subtitle");
    dom.chatTags = document.getElementById("chat-tags");
    dom.chatMeta = document.getElementById("chat-meta");
    dom.toggleChatOfficialButton = document.getElementById("toggle-chat-official-button");
    dom.toggleChatBlockButton = document.getElementById("toggle-chat-block-button");
    dom.deleteChatButton = document.getElementById("delete-chat-button");
    dom.chatStatus = document.getElementById("chat-status");
    dom.chatMessagesList = document.getElementById("chat-messages-list");

    dom.broadcastForm = document.getElementById("broadcast-form");
    dom.broadcastTitleInput = document.getElementById("broadcast-title-input");
    dom.broadcastBodyInput = document.getElementById("broadcast-body-input");
    dom.broadcastDeepLinkInput = document.getElementById("broadcast-deep-link-input");
    dom.broadcastSendButton = document.getElementById("broadcast-send-button");
    dom.broadcastStatus = document.getElementById("broadcast-status");
  }

  function bindEvents() {
    dom.loginForm.addEventListener("submit", onLoginSubmit);
    dom.refreshDashboardButton.addEventListener("click", () => void refreshDashboard({ announce: true }));
    dom.logoutButton.addEventListener("click", onLogoutClick);
    dom.accessForm.addEventListener("submit", onAccessSubmit);
    dom.cleanupLegacyButton.addEventListener("click", () => void cleanupLegacyUsers());
    dom.bulkDeleteFilteredButton.addEventListener("click", () => void bulkDeleteFilteredUsers());
    dom.createUserForm.addEventListener("submit", onCreateUserSubmit);
    dom.appUpdatePolicyForm.addEventListener("submit", onAppUpdatePolicySubmit);
    dom.softPromptUpdateButton.addEventListener("click", onSoftPromptUpdateClick);
    dom.requireLatestUpdateButton.addEventListener("click", onRequireLatestUpdateClick);
    dom.resetUpdatePolicyButton.addEventListener("click", onResetUpdatePolicyClick);
    dom.usersRefreshButton.addEventListener("click", () => void loadUsers({ announce: true }));
    dom.usersSearchInput.addEventListener("input", onUsersSearchInput);
    dom.usersPlaceholdersOnlyInput.addEventListener("change", onUsersPlaceholdersToggle);
    dom.userLookupForm.addEventListener("submit", onQuickLookupSubmit);
    dom.usersList.addEventListener("click", onUsersListClick);
    dom.selectedUserRefreshButton.addEventListener("click", () => void loadSelectedUserChats());
    dom.selectedUserPremiumButton.addEventListener("click", () => void toggleSelectedUserPremium());
    dom.selectedUserContent.addEventListener("click", onSelectedUserPanelClick);
    dom.communitiesRefreshButton.addEventListener("click", () => void loadCommunities({ announce: true }));
    dom.communitiesSearchInput.addEventListener("input", onCommunitiesSearchInput);
    dom.communitiesFilterSelect.addEventListener("change", onCommunitiesFilterChange);
    dom.communitiesList.addEventListener("click", onCommunitiesListClick);
    dom.chatRefreshButton.addEventListener("click", () => void loadSelectedChatMessages());
    dom.toggleChatOfficialButton.addEventListener("click", () => void toggleChatOfficial());
    dom.toggleChatBlockButton.addEventListener("click", () => void toggleChatBlocked());
    dom.deleteChatButton.addEventListener("click", () => void deleteSelectedChat());
    dom.broadcastForm.addEventListener("submit", onBroadcastSubmit);
  }

  function restoreConfig() {
    try {
      const raw = localStorage.getItem(STORAGE_CONFIG_KEY);
      if (!raw) {
        return;
      }
      const parsed = JSON.parse(raw);
      state.apiBase = normalizeApiBase(parsed.apiBase) || DEFAULT_API_BASE;
      state.adminLogin = normalizeString(parsed.adminLogin) || "admin";
      state.adminPassword = normalizeString(parsed.adminPassword) || "";
    } catch (error) {
      state.apiBase = DEFAULT_API_BASE;
    }
  }

  function persistConfig() {
    localStorage.setItem(
      STORAGE_CONFIG_KEY,
      JSON.stringify({
        apiBase: state.apiBase,
        adminLogin: state.adminLogin,
        adminPassword: state.adminPassword,
      }),
    );
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
    } catch (error) {
      state.session = null;
    }
  }

  function persistSession() {
    if (!state.session) {
      localStorage.removeItem(STORAGE_SESSION_KEY);
      return;
    }
    localStorage.setItem(STORAGE_SESSION_KEY, JSON.stringify(state.session));
  }

  function clearSession() {
    state.session = null;
    state.authUser = null;
    state.summary = null;
    state.users = [];
    state.communities = [];
    state.selectedUser = null;
    state.selectedUserChats = [];
    state.selectedChat = null;
    state.selectedChatMessages = [];
    state.chatFocusUserId = null;
    persistSession();
  }

  function hydrateAuthForm() {
    dom.apiBaseInput.value = state.apiBase;
    dom.loginAdminLogin.value = state.adminLogin;
    dom.loginAdminPassword.value = state.adminPassword;
  }

  function hydrateAccessForm() {
    dom.adminLoginInput.value = state.adminLogin;
    dom.adminPasswordInput.value = state.adminPassword;
  }

  async function onLoginSubmit(event) {
    event.preventDefault();

    const identifier = normalizeString(dom.loginIdentifier.value);
    const password = dom.loginPassword.value;
    const adminLogin = normalizeString(dom.loginAdminLogin.value);
    const adminPassword = normalizeString(dom.loginAdminPassword.value);

    state.apiBase = normalizeApiBase(dom.apiBaseInput.value) || DEFAULT_API_BASE;
    state.adminLogin = adminLogin || "admin";
    state.adminPassword = adminPassword;
    persistConfig();
    hydrateAccessForm();

    if (!identifier || !password) {
      setStatus("auth", "Enter your Prime Messaging account credentials first.");
      return;
    }
    if (!state.adminLogin || !state.adminPassword) {
      setStatus("auth", "Enter the server admin login and password too.");
      return;
    }

    setBusy("auth", true);
    setStatus("auth", "Signing in…");

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
      await bootstrapAuthenticatedSession();
      dom.loginPassword.value = "";
      setStatus("auth", "");
    } catch (error) {
      clearSession();
      showAuthScreen();
      setStatus("auth", humanizeApiError(error, "Could not sign in. Check the credentials and try again."));
    } finally {
      setBusy("auth", false);
    }
  }

  async function bootstrapAuthenticatedSession() {
    showAppScreen();
    setConnectionState("connecting");

    try {
      await ensureFreshSession();

      if (!isAllowedAdminUser(state.authUser)) {
        const message = "This admin console is available only to @mihran.";
        clearSession();
        showAuthScreen();
        setStatus("auth", message);
        return;
      }

      renderSessionIdentity();
      try {
        await refreshDashboard();
        setConnectionState("connected");
      } catch (error) {
        setConnectionState("warning");
        setStatus("access", humanizeApiError(error, "Signed in, but admin data could not be loaded."));
      }
    } catch (error) {
      clearSession();
      showAuthScreen();
      setConnectionState("idle");
      setStatus("auth", humanizeApiError(error, "The saved session could not be restored. Sign in again."));
    }
  }

  async function ensureFreshSession() {
    if (!state.session) {
      throw new Error("missing_session");
    }
    const me = await request("/auth/me");
    state.authUser = me;
    return me;
  }

  function isAllowedAdminUser(user) {
    return normalizeUsername(user?.profile?.username) === ADMIN_USERNAME;
  }

  async function refreshDashboard(options = {}) {
    const announce = Boolean(options.announce);
    setBusy("dashboard", true);
    if (announce) {
      setStatus("access", "Refreshing admin data…");
    }

    try {
      await Promise.all([
        loadSummary(),
        loadAppVersionPolicy(),
        loadUsers({ preserveSelection: true }),
        loadCommunities(),
      ]);
      if (state.selectedUser?.id) {
        await loadSelectedUserChats();
      } else if (state.users.length) {
        await selectUserById(state.users[0].id);
      }
      if (state.selectedChat?.id) {
        await loadSelectedChatMessages();
      }
      if (announce) {
        setStatus("access", "Admin data refreshed.");
      }
    } finally {
      setBusy("dashboard", false);
    }
  }

  async function onAccessSubmit(event) {
    event.preventDefault();
    state.adminLogin = normalizeString(dom.adminLoginInput.value) || "admin";
    state.adminPassword = normalizeString(dom.adminPasswordInput.value);
    dom.loginAdminLogin.value = state.adminLogin;
    dom.loginAdminPassword.value = state.adminPassword;
    persistConfig();

    if (!state.adminLogin || !state.adminPassword) {
      setStatus("access", "Both admin login and admin password are required.");
      return;
    }

    setBusy("access", true);
    setStatus("access", "Validating admin access…");

    try {
      await loadSummary();
      await loadAppVersionPolicy();
      await loadUsers({ preserveSelection: true });
      await loadCommunities();
      if (state.selectedUser?.id) {
        await loadSelectedUserChats();
      }
      if (state.selectedChat?.id) {
        await loadSelectedChatMessages();
      }
      setConnectionState("connected");
      setStatus("access", "Admin credentials saved and validated.");
    } catch (error) {
      setConnectionState("warning");
      setStatus("access", humanizeApiError(error, "Could not validate admin access."));
    } finally {
      setBusy("access", false);
    }
  }

  async function loadSummary() {
    try {
      state.summary = await adminRequest("/admin/summary");
      renderSummary();
    } catch (error) {
      state.summary = null;
      renderSummary();
      throw error;
    }
  }

  async function loadAppVersionPolicy() {
    try {
      state.appVersionPolicy = await adminRequest("/admin/app-version-policy");
      renderAppVersionPolicy();
    } catch (error) {
      state.appVersionPolicy = null;
      renderAppVersionPolicy();
      throw error;
    }
  }

  async function loadUsers(options = {}) {
    const preserveSelection = options.preserveSelection !== false;
    const announce = Boolean(options.announce);
    setBusy("users", true);
    if (announce) {
      setStatus("users", "Loading users…");
    }

    try {
      const params = new URLSearchParams();
      if (state.usersSearch) {
        params.set("query", state.usersSearch);
      }
      if (state.placeholdersOnly) {
        params.set("placeholders_only", "1");
      }

      state.users = await adminRequest(`/admin/users${params.toString() ? `?${params.toString()}` : ""}`);
      setStatus("users", state.users.length ? "" : "No users match the current filter.");

      if (preserveSelection && state.selectedUser?.id) {
        state.selectedUser = state.users.find((user) => user.id === state.selectedUser.id) || state.selectedUser;
      } else if (!state.selectedUser && state.users.length) {
        state.selectedUser = state.users[0];
      }

      renderUsers();
      renderSelectedUser();
    } catch (error) {
      setStatus("users", humanizeApiError(error, "Could not load users right now."));
      renderUsers();
      throw error;
    } finally {
      setBusy("users", false);
    }
  }

  async function loadCommunities(options = {}) {
    const announce = Boolean(options.announce);
    setBusy("communities", true);
    if (announce) {
      setStatus("communities", "Loading channels and communities…");
    }

    try {
      const params = new URLSearchParams();
      params.set("kinds", COMMUNITY_KINDS.join(","));
      params.set("include_blocked", "1");
      state.communities = await adminRequest(`/admin/chats?${params.toString()}`);
      setStatus("communities", state.communities.length ? "" : "No channels or communities found.");
      renderCommunities();
    } catch (error) {
      setStatus("communities", humanizeApiError(error, "Could not load channels and communities."));
      renderCommunities();
      throw error;
    } finally {
      setBusy("communities", false);
    }
  }

  async function cleanupLegacyUsers() {
    if (!window.confirm("Delete every legacy placeholder user from the backend now?")) {
      return;
    }

    setBusy("maintenance", true);
    setStatus("maintenance", "Removing legacy placeholder users…");

    try {
      const payload = await adminRequest("/admin/cleanup/legacy-placeholders", {
        method: "POST",
        body: {},
      });
      const removed = Number(payload?.removed || 0);
      setStatus("maintenance", `Removed legacy placeholders: ${removed}.`);
      await refreshDashboard();
    } catch (error) {
      setStatus("maintenance", humanizeApiError(error, "Could not clean up legacy placeholders."));
    } finally {
      setBusy("maintenance", false);
    }
  }

  async function onAppUpdatePolicySubmit(event) {
    event.preventDefault();
    await saveAppUpdatePolicy(
      {
        latestVersion: normalizeString(dom.updateLatestVersionInput.value),
        minimumSupportedVersion: normalizeString(dom.updateMinimumVersionInput.value),
        appStoreURL: normalizeString(dom.updateAppStoreURLInput.value),
        title: normalizeString(dom.updateTitleInput.value),
        message: normalizeString(dom.updateMessageInput.value),
        requiredTitle: normalizeString(dom.updateRequiredTitleInput.value),
        requiredMessage: normalizeString(dom.updateRequiredMessageInput.value),
      },
      "Saving app update policy…",
      "App update policy saved."
    );
  }

  async function onSoftPromptUpdateClick() {
    const latestVersion = normalizeString(dom.updateLatestVersionInput.value);
    if (!latestVersion) {
      setStatus("updatePolicy", "Enter the latest version first.");
      return;
    }
    await saveAppUpdatePolicy(
      {
        latestVersion,
        minimumSupportedVersion: normalizeString(dom.updateMinimumVersionInput.value),
        appStoreURL: normalizeString(dom.updateAppStoreURLInput.value),
        title: normalizeString(dom.updateTitleInput.value),
        message: normalizeString(dom.updateMessageInput.value),
        requiredTitle: normalizeString(dom.updateRequiredTitleInput.value),
        requiredMessage: normalizeString(dom.updateRequiredMessageInput.value),
      },
      `Prompting every version below ${latestVersion} to update…`,
      `Soft update prompt enabled for versions below ${latestVersion}.`
    );
  }

  async function onRequireLatestUpdateClick() {
    const latestVersion = normalizeString(dom.updateLatestVersionInput.value);
    if (!latestVersion) {
      setStatus("updatePolicy", "Enter the latest version first.");
      return;
    }
    await saveAppUpdatePolicy(
      {
        latestVersion,
        minimumSupportedVersion: latestVersion,
        appStoreURL: normalizeString(dom.updateAppStoreURLInput.value),
        title: normalizeString(dom.updateTitleInput.value),
        message: normalizeString(dom.updateMessageInput.value),
        requiredTitle: normalizeString(dom.updateRequiredTitleInput.value),
        requiredMessage: normalizeString(dom.updateRequiredMessageInput.value),
      },
      `Requiring version ${latestVersion} for everyone older…`,
      `Mandatory update enabled. Versions below ${latestVersion} will be blocked.`
    );
  }

  function onResetUpdatePolicyClick() {
    const policy = state.appVersionPolicy || {};
    dom.updateTitleInput.value = normalizeString(policy.title) || "Update Available";
    dom.updateMessageInput.value = normalizeString(policy.message) || "A newer version of Prime Messaging is available.";
    dom.updateRequiredTitleInput.value = normalizeString(policy.requiredTitle) || "Update Required";
    dom.updateRequiredMessageInput.value = normalizeString(policy.requiredMessage) || "Please update Prime Messaging to continue.";
    setStatus("updatePolicy", "Banner text reset to the last saved policy.");
  }

  async function saveAppUpdatePolicy(payload, pendingMessage, successMessage) {
    setBusy("updatePolicy", true);
    setStatus("updatePolicy", pendingMessage);

    try {
      state.appVersionPolicy = await adminRequest("/admin/app-version-policy", {
        method: "PATCH",
        body: payload,
      });
      renderAppVersionPolicy();
      setStatus("updatePolicy", successMessage);
    } catch (error) {
      setStatus("updatePolicy", humanizeApiError(error, "Could not save the app update policy."));
    } finally {
      setBusy("updatePolicy", false);
    }
  }

  async function bulkDeleteFilteredUsers() {
    const candidates = state.users.filter(canDeleteUser);
    if (!candidates.length) {
      setStatus("maintenance", "There are no deletable users in the current filter.");
      return;
    }

    if (!window.confirm(`Delete ${candidates.length} user(s) from the current filter? This also removes chats, messages, sessions, and device tokens.`)) {
      return;
    }

    setBusy("maintenance", true);
    setStatus("maintenance", "Deleting filtered users…");

    try {
      const payload = await adminRequest("/admin/users/bulk-delete", {
        method: "POST",
        body: {
          user_ids: candidates.map((user) => user.id),
        },
      });
      const removed = Number(payload?.removed || 0);
      setStatus("maintenance", `Removed users: ${removed}.`);
      if (state.selectedUser && candidates.some((user) => user.id === state.selectedUser.id)) {
        state.selectedUser = null;
        state.selectedUserChats = [];
      }
      await refreshDashboard();
    } catch (error) {
      setStatus("maintenance", humanizeApiError(error, "Could not bulk delete the filtered users."));
    } finally {
      setBusy("maintenance", false);
    }
  }

  async function onCreateUserSubmit(event) {
    event.preventDefault();

    const displayName = normalizeString(dom.createDisplayNameInput.value);
    const username = normalizeUsername(dom.createUsernameInput.value);
    const password = normalizeString(dom.createPasswordInput.value);

    if (!username || !password) {
      setStatus("createUser", "Username and password are required.");
      return;
    }

    setBusy("createUser", true);
    setStatus("createUser", "Creating account…");

    try {
      const createdUser = await adminRequest("/admin/users/create", {
        method: "POST",
        body: {
          display_name: displayName || username,
          username,
          password,
        },
      });
      dom.createDisplayNameInput.value = "";
      dom.createUsernameInput.value = "";
      dom.createPasswordInput.value = "";
      setStatus("createUser", `Account @${createdUser.username || username} created.`);
      await loadUsers({ preserveSelection: true });
      await loadSummary();
      await selectUserById(createdUser.id);
    } catch (error) {
      setStatus("createUser", humanizeApiError(error, "Could not create the account."));
    } finally {
      setBusy("createUser", false);
    }
  }

  function onUsersSearchInput(event) {
    state.usersSearch = normalizeString(event.target.value);
    clearTimeout(state.usersDebounceTimer);
    state.usersDebounceTimer = window.setTimeout(() => {
      void loadUsers({ preserveSelection: true });
    }, 250);
  }

  function onUsersPlaceholdersToggle(event) {
    state.placeholdersOnly = Boolean(event.target.checked);
    void loadUsers({ preserveSelection: true });
  }

  async function onQuickLookupSubmit(event) {
    event.preventDefault();
    state.quickLookup = normalizeUsername(dom.userLookupInput.value);
    if (!state.quickLookup) {
      setStatus("users", "Enter a username to open a user profile.");
      return;
    }

    const localMatch = findUserInList(state.quickLookup);
    if (localMatch) {
      await selectUserById(localMatch.id);
      return;
    }

    setStatus("users", "Looking up user…");
    try {
      const params = new URLSearchParams();
      params.set("query", state.quickLookup);
      const users = await adminRequest(`/admin/users?${params.toString()}`);
      const match = users.find((user) => normalizeUsername(user.username) === state.quickLookup) || users[0];
      if (!match) {
        setStatus("users", "User not found.");
        return;
      }
      state.users = users;
      await selectUserById(match.id);
      setStatus("users", "");
      renderUsers();
    } catch (error) {
      setStatus("users", humanizeApiError(error, "Could not look up that user."));
    }
  }

  function onUsersListClick(event) {
    const deleteButton = event.target.closest("[data-delete-user-id]");
    if (deleteButton) {
      const userId = deleteButton.getAttribute("data-delete-user-id");
      void deleteUserById(userId);
      return;
    }

    const row = event.target.closest("[data-user-id]");
    if (!row) {
      return;
    }
    const userId = row.getAttribute("data-user-id");
    void selectUserById(userId);
  }

  async function selectUserById(userId) {
    if (!userId) {
      return;
    }
    const existing = state.users.find((user) => user.id === userId) || state.selectedUser;
    if (!existing) {
      return;
    }
    state.selectedUser = existing;
    state.selectedUserChats = [];
    state.chatFocusUserId = state.selectedUser.id;
    renderUsers();
    renderSelectedUser();
    await loadSelectedUserChats();
  }

  async function loadSelectedUserChats() {
    if (!state.selectedUser?.id) {
      renderSelectedUser();
      return;
    }

    setBusy("selectedUser", true);
    setStatus("selectedUser", "Loading user chats…");

    try {
      const params = new URLSearchParams();
      params.set("user_id", state.selectedUser.id);
      state.selectedUserChats = await adminRequest(`/admin/chats?${params.toString()}`);
      setStatus("selectedUser", state.selectedUserChats.length ? "" : "No chats found for this user.");
      renderSelectedUser();
    } catch (error) {
      setStatus("selectedUser", humanizeApiError(error, "Could not load chats for this user."));
      renderSelectedUser();
    } finally {
      setBusy("selectedUser", false);
    }
  }

  function onSelectedUserPanelClick(event) {
    const banButton = event.target.closest("[data-ban-days]");
    if (banButton) {
      const durationDays = Number(banButton.getAttribute("data-ban-days"));
      void banSelectedUser(durationDays);
      return;
    }

    const deleteButton = event.target.closest("#delete-selected-user-button");
    if (deleteButton) {
      void deleteSelectedUser();
      return;
    }

    const chatOpenButton = event.target.closest("[data-user-chat-id]");
    if (chatOpenButton) {
      const chatId = chatOpenButton.getAttribute("data-user-chat-id");
      const chat = state.selectedUserChats.find((item) => item.id === chatId);
      if (chat) {
        void selectChat(chat, state.selectedUser?.id || null);
      }
    }
  }

  async function banSelectedUser(durationDays) {
    if (!state.selectedUser?.id || !durationDays) {
      return;
    }

    setBusy("selectedUser", true);
    setStatus("selectedUser", `Applying ${durationDays}-day ban…`);

    try {
      const payload = await adminRequest(`/admin/users/${encodeURIComponent(state.selectedUser.id)}/ban`, {
        method: "POST",
        body: { duration_days: durationDays },
      });
      const bannedUntil = payload?.bannedUntil || payload?.banned_until || null;
      state.selectedUser = {
        ...state.selectedUser,
        bannedUntil,
      };
      replaceUserInList(state.selectedUser);
      setStatus(
        "selectedUser",
        bannedUntil
          ? `User banned until ${formatDateTime(bannedUntil)}.`
          : "Ban applied.",
      );
      renderUsers();
      renderSelectedUser();
    } catch (error) {
      setStatus("selectedUser", humanizeApiError(error, "Could not apply the ban."));
    } finally {
      setBusy("selectedUser", false);
    }
  }

  async function toggleSelectedUserPremium() {
    if (!state.selectedUser?.id) {
      return;
    }

    const isEnabled = Boolean(state.selectedUser.primePremium?.isEnabled);
    setBusy("selectedUser", true);
    setStatus("selectedUser", isEnabled ? "Disabling Prime Premium…" : "Enabling Prime Premium…");

    try {
      const payload = await adminRequest(`/admin/users/${encodeURIComponent(state.selectedUser.id)}/premium`, {
        method: "PATCH",
        body: { is_enabled: !isEnabled },
      });
      state.selectedUser = payload;
      replaceUserInList(payload);
      renderUsers();
      renderSelectedUser();
      setStatus("selectedUser", payload.primePremium?.isEnabled ? "Prime Premium enabled." : "Prime Premium disabled.");
    } catch (error) {
      setStatus("selectedUser", humanizeApiError(error, "Could not change Prime Premium access."));
    } finally {
      setBusy("selectedUser", false);
    }
  }

  async function deleteSelectedUser() {
    if (!state.selectedUser?.id) {
      return;
    }
    await deleteUserById(state.selectedUser.id);
  }

  async function deleteUserById(userId) {
    const user = state.users.find((item) => item.id === userId) || state.selectedUser;
    if (!user) {
      return;
    }
    if (!canDeleteUser(user)) {
      setStatus("users", "The admin account cannot be deleted from the admin console.");
      return;
    }

    const display = user.displayName || `@${user.username}`;
    if (!window.confirm(`Delete ${display} and all related chats, messages, sessions, and device tokens?`)) {
      return;
    }

    setStatus("users", "Deleting user…");
    if (state.selectedUser?.id === user.id) {
      setStatus("selectedUser", "Deleting user…");
    }

    try {
      await adminRequest(`/admin/users/${encodeURIComponent(user.id)}`, {
        method: "DELETE",
      });
      setStatus("users", `${display} deleted.`);
      if (state.selectedUser?.id === user.id) {
        state.selectedUser = null;
        state.selectedUserChats = [];
      }
      await refreshDashboard();
    } catch (error) {
      const message = humanizeApiError(error, "Could not delete this user.");
      setStatus("users", message);
      if (state.selectedUser?.id === user.id) {
        setStatus("selectedUser", message);
      }
    }
  }

  function onCommunitiesSearchInput(event) {
    state.communitySearch = normalizeString(event.target.value).toLowerCase();
    renderCommunities();
  }

  function onCommunitiesFilterChange(event) {
    state.communityFilter = normalizeString(event.target.value) || "all";
    renderCommunities();
  }

  function onCommunitiesListClick(event) {
    const row = event.target.closest("[data-community-chat-id]");
    if (!row) {
      return;
    }
    const chatId = row.getAttribute("data-community-chat-id");
    const chat = state.communities.find((item) => item.id === chatId);
    if (chat) {
      void selectChat(chat, null);
    }
  }

  async function selectChat(chat, focusUserId) {
    state.selectedChat = chat;
    state.selectedChatMessages = [];
    state.chatFocusUserId = focusUserId || null;
    renderChatInspector();
    await loadSelectedChatMessages();
  }

  async function loadSelectedChatMessages() {
    if (!state.selectedChat?.id) {
      renderChatInspector();
      return;
    }

    setBusy("chat", true);
    setStatus("chat", "Loading messages…");

    try {
      const params = new URLSearchParams();
      params.set("chat_id", state.selectedChat.id);
      const payload = await adminRequest(`/admin/messages?${params.toString()}`);
      if (payload?.chat) {
        state.selectedChat = payload.chat;
        replaceChatEverywhere(payload.chat);
      }
      state.selectedChatMessages = Array.isArray(payload?.messages) ? payload.messages : [];
      setStatus("chat", state.selectedChatMessages.length ? "" : "No messages in this chat.");
      renderSelectedUser();
      renderCommunities();
      renderChatInspector();
    } catch (error) {
      setStatus("chat", humanizeApiError(error, "Could not load messages for this chat."));
      renderChatInspector();
    } finally {
      setBusy("chat", false);
    }
  }

  async function toggleChatOfficial() {
    if (!state.selectedChat?.id || !isVerifiableCommunity(state.selectedChat)) {
      return;
    }

    setBusy("chat", true);
    setStatus("chat", "Updating official status…");

    try {
      const updatedChat = await adminRequest(`/admin/chats/${encodeURIComponent(state.selectedChat.id)}/official`, {
        method: "PATCH",
        body: {
          is_official: !Boolean(state.selectedChat?.communityDetails?.isOfficial),
        },
      });
      state.selectedChat = updatedChat;
      replaceChatEverywhere(updatedChat);
      setStatus("chat", updatedChat?.communityDetails?.isOfficial ? "Official badge enabled." : "Official badge removed.");
      renderSelectedUser();
      renderCommunities();
      renderChatInspector();
    } catch (error) {
      setStatus("chat", humanizeApiError(error, "Could not update the official badge."));
    } finally {
      setBusy("chat", false);
    }
  }

  async function toggleChatBlocked() {
    if (!state.selectedChat?.id || state.selectedChat?.type !== "group") {
      return;
    }

    setBusy("chat", true);
    setStatus("chat", "Updating block state…");

    try {
      const updatedChat = await adminRequest(`/admin/chats/${encodeURIComponent(state.selectedChat.id)}/block`, {
        method: "PATCH",
        body: {
          is_blocked: !Boolean(state.selectedChat?.communityDetails?.isBlockedByAdmin),
        },
      });
      state.selectedChat = updatedChat;
      replaceChatEverywhere(updatedChat);
      setStatus("chat", updatedChat?.communityDetails?.isBlockedByAdmin ? "Chat blocked by admin." : "Chat unblocked.");
      renderSelectedUser();
      renderCommunities();
      renderChatInspector();
    } catch (error) {
      setStatus("chat", humanizeApiError(error, "Could not update the chat block state."));
    } finally {
      setBusy("chat", false);
    }
  }

  async function deleteSelectedChat() {
    if (!state.selectedChat?.id) {
      return;
    }
    const label = state.selectedChat.title || "this chat";
    if (!window.confirm(`Delete ${label} and all its messages?`)) {
      return;
    }

    setBusy("chat", true);
    setStatus("chat", "Deleting chat…");

    try {
      await adminRequest(`/admin/chats/${encodeURIComponent(state.selectedChat.id)}`, {
        method: "DELETE",
      });
      removeChatEverywhere(state.selectedChat.id);
      state.selectedChat = null;
      state.selectedChatMessages = [];
      setStatus("chat", "Chat deleted.");
      renderSelectedUser();
      renderCommunities();
      renderChatInspector();
      await loadSummary();
    } catch (error) {
      setStatus("chat", humanizeApiError(error, "Could not delete the chat."));
    } finally {
      setBusy("chat", false);
    }
  }

  async function onBroadcastSubmit(event) {
    event.preventDefault();
    const title = normalizeString(dom.broadcastTitleInput.value);
    const body = normalizeString(dom.broadcastBodyInput.value);
    const deepLink = normalizeString(dom.broadcastDeepLinkInput.value);

    if (!title || !body) {
      setStatus("broadcast", "Push title and body are required.");
      return;
    }

    setBusy("broadcast", true);
    setStatus("broadcast", "Queueing push broadcast…");

    try {
      const payload = await adminRequest("/admin/push/broadcast", {
        method: "POST",
        body: {
          title,
          body,
          deep_link: deepLink || null,
          category: "admin_broadcast",
          notification_type: "broadcast",
        },
      });
      if (payload?.queued) {
        setStatus("broadcast", `Push queued for ${Number(payload.recipientCount || 0)} device(s).`);
      } else {
        setStatus("broadcast", "No active alert device tokens were found.");
      }
      dom.broadcastTitleInput.value = "";
      dom.broadcastBodyInput.value = "";
      dom.broadcastDeepLinkInput.value = "";
    } catch (error) {
      setStatus("broadcast", humanizeApiError(error, "Could not queue the push broadcast."));
    } finally {
      setBusy("broadcast", false);
    }
  }

  async function request(path, options = {}) {
    const {
      method = "GET",
      body,
      auth = true,
      headers = {},
      retrying = false,
    } = options;

    const url = `${state.apiBase.replace(/\/+$/, "")}${path.startsWith("/") ? path : `/${path}`}`;
    const requestHeaders = {
      "Content-Type": "application/json",
      "X-Prime-Platform": "web-admin",
      "X-Prime-Device-ID": "prime-admin-console",
      "X-Prime-Device-Name": "Prime Messaging Admin Console",
      "X-Prime-Device-Model": navigator.userAgent || "browser",
      "X-Prime-App-Version": "admin-web-0.1.0",
      ...headers,
    };

    if (auth && state.session?.accessToken) {
      requestHeaders.Authorization = `Bearer ${state.session.accessToken}`;
    }

    const response = await fetch(url, {
      method,
      headers: requestHeaders,
      body: body === undefined ? undefined : JSON.stringify(body),
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
      const error = new Error(payload?.error || `http_${response.status}`);
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
      return true;
    } catch (error) {
      return false;
    }
  }

  async function adminRequest(path, options = {}) {
    if (!state.adminLogin || !state.adminPassword) {
      throw new Error("admin_credentials_required");
    }

    return request(path, {
      ...options,
      headers: {
        ...(options.headers || {}),
        "X-Prime-Admin-Login": state.adminLogin,
        "X-Prime-Admin-Password": state.adminPassword,
      },
    });
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
    state.authUser = payload.user || state.authUser;
    persistSession();
  }

  function renderAll() {
    renderVisibility();
    renderConnectionState();
    renderSessionIdentity();
    renderSummary();
    renderAppVersionPolicy();
    renderUsers();
    renderSelectedUser();
    renderCommunities();
    renderChatInspector();
    renderStatuses();
    renderBusyStates();
  }

  function renderVisibility() {
    if (state.session) {
      showAppScreen();
      return;
    }
    showAuthScreen();
  }

  function showAuthScreen() {
    dom.authScreen.classList.remove("hidden");
    dom.appScreen.classList.add("hidden");
  }

  function showAppScreen() {
    dom.authScreen.classList.add("hidden");
    dom.appScreen.classList.remove("hidden");
  }

  function renderSessionIdentity() {
    const profile = state.authUser?.profile || {};
    dom.sessionName.textContent = profile.displayName || "Admin";
    dom.sessionHandle.textContent = profile.username ? `@${profile.username}` : "@unknown";
  }

  function renderConnectionState() {
    dom.connectionPill.className = "status-pill";
    switch (state.connectionState) {
      case "connected":
        dom.connectionPill.textContent = "Connected";
        dom.connectionPill.classList.add("connected");
        break;
      case "warning":
        dom.connectionPill.textContent = "Needs attention";
        dom.connectionPill.classList.add("warning");
        break;
      case "connecting":
        dom.connectionPill.textContent = "Connecting";
        break;
      default:
        dom.connectionPill.textContent = "Idle";
        break;
    }
  }

  function setConnectionState(kind) {
    state.connectionState = kind;
    dom.connectionPill.className = "status-pill";
    switch (kind) {
      case "connected":
        dom.connectionPill.textContent = "Connected";
        dom.connectionPill.classList.add("connected");
        break;
      case "warning":
        dom.connectionPill.textContent = "Needs attention";
        dom.connectionPill.classList.add("warning");
        break;
      case "connecting":
        dom.connectionPill.textContent = "Connecting";
        break;
      default:
        dom.connectionPill.textContent = "Idle";
        break;
    }
  }

  function renderSummary() {
    const summary = state.summary || {};
    dom.summaryUsers.textContent = formatNumber(summary.users);
    dom.summaryLegacyUsers.textContent = formatNumber(summary.legacyUsers || summary.legacy_users);
    dom.summaryChats.textContent = formatNumber(summary.chats);
    dom.summaryMessages.textContent = formatNumber(summary.messages);
    dom.summarySessions.textContent = formatNumber(summary.sessions);
    dom.summaryDeviceTokens.textContent = formatNumber(summary.deviceTokens || summary.device_tokens);
  }

  function renderAppVersionPolicy() {
    const policy = state.appVersionPolicy || {};
    dom.updateLatestVersionInput.value = normalizeString(policy.latestVersion);
    dom.updateMinimumVersionInput.value = normalizeString(policy.minimumSupportedVersion);
    dom.updateAppStoreURLInput.value = normalizeString(policy.appStoreURL);
    dom.updateTitleInput.value = normalizeString(policy.title);
    dom.updateMessageInput.value = normalizeString(policy.message);
    dom.updateRequiredTitleInput.value = normalizeString(policy.requiredTitle);
    dom.updateRequiredMessageInput.value = normalizeString(policy.requiredMessage);
  }

  function renderUsers() {
    dom.usersSearchInput.value = state.usersSearch;
    dom.usersPlaceholdersOnlyInput.checked = state.placeholdersOnly;
    dom.userLookupInput.value = state.quickLookup;
    dom.usersCount.textContent = `${state.users.length} user${state.users.length === 1 ? "" : "s"}`;
    dom.usersFilterHint.textContent = state.placeholdersOnly
      ? "Showing only legacy placeholders"
      : state.usersSearch
        ? `Filtered by “${state.usersSearch}”`
        : "Showing all accounts";
    dom.bulkDeleteFilteredButton.disabled = !state.users.some(canDeleteUser) || state.busy.maintenance;

    if (!state.users.length) {
      dom.usersList.innerHTML = `<div class="empty-state">No users match the current filter.</div>`;
      return;
    }

    dom.usersList.innerHTML = state.users
      .map((user) => {
        const selected = state.selectedUser?.id === user.id ? " selected" : "";
        const tags = [
          user.isLegacyPlaceholder ? `<span class="tag legacy">LEGACY</span>` : "",
          user.primePremium?.isEnabled ? `<span class="tag">PREMIUM</span>` : "",
          isUserBanned(user) ? `<span class="tag banned">BANNED</span>` : "",
        ].join("");
        const subtitle = [
          user.email || "",
          user.phoneNumber || "",
          `created ${formatDateTime(user.createdAt)}`,
        ]
          .filter(Boolean)
          .join(" · ");
        return `
          <article class="entity-row${selected}" data-user-id="${escapeHtml(user.id)}">
            <div class="row-top">
              <div>
                <div class="row-title">${escapeHtml(user.displayName || `@${user.username}`)}</div>
                <div class="row-subtitle">@${escapeHtml(user.username || "unknown")}</div>
              </div>
              <div class="identity-tags">${tags}</div>
            </div>
            <div class="row-meta">
              <div class="row-stats">${escapeHtml(subtitle)}</div>
              <div class="row-stats">${formatNumber(user.chatCount)} chats · ${formatNumber(user.sentMessageCount)} msgs · ${formatNumber(user.sessionCount)} sessions</div>
            </div>
            <div class="row-actions">
              <button class="ghost-button" type="button">Inspect</button>
              ${canDeleteUser(user) ? `<button class="ghost-button danger" type="button" data-delete-user-id="${escapeHtml(user.id)}">Delete</button>` : ""}
            </div>
          </article>
        `;
      })
      .join("");
  }

  function renderSelectedUser() {
    const user = state.selectedUser;
    if (!user) {
      dom.selectedUserEmpty.classList.remove("hidden");
      dom.selectedUserContent.classList.add("hidden");
      return;
    }

    dom.selectedUserEmpty.classList.add("hidden");
    dom.selectedUserContent.classList.remove("hidden");
    dom.selectedUserName.textContent = user.displayName || `@${user.username}`;
    dom.selectedUserHandle.textContent = `@${user.username || "unknown"}`;
    dom.selectedUserChatCount.textContent = formatNumber(user.chatCount);
    dom.selectedUserMessageCount.textContent = formatNumber(user.sentMessageCount);
    dom.selectedUserSessionCount.textContent = formatNumber(user.sessionCount);

    const tags = [];
    if (user.accountKind) {
      tags.push(`<span>${escapeHtml(String(user.accountKind))}</span>`);
    }
    if (user.isLegacyPlaceholder) {
      tags.push(`<span class="tag legacy">LEGACY</span>`);
    }
    if (user.primePremium?.isEnabled) {
      tags.push(`<span class="tag">PREMIUM</span>`);
    }
    if (isUserBanned(user)) {
      tags.push(`<span class="tag banned">BANNED</span>`);
    }
    dom.selectedUserTags.innerHTML = tags.join("");

    const metaLines = [
      user.email ? `E-mail: ${escapeHtml(user.email)}` : "",
      user.phoneNumber ? `Phone: ${escapeHtml(user.phoneNumber)}` : "",
      `Created: ${escapeHtml(formatDateTime(user.createdAt))}`,
      user.primePremium?.isEnabled
        ? `Prime Premium: enabled${user.primePremium.grantedAt ? ` (${escapeHtml(formatDateTime(user.primePremium.grantedAt))})` : ""}`
        : "Prime Premium: disabled",
      user.guestExpiresAt ? `Guest expires: ${escapeHtml(formatDateTime(user.guestExpiresAt))}` : "",
      user.bannedUntil ? `Banned until: ${escapeHtml(formatDateTime(user.bannedUntil))}` : "",
    ].filter(Boolean);
    dom.selectedUserMeta.innerHTML = metaLines.join("<br />");
    dom.selectedUserPremiumButton.textContent = user.primePremium?.isEnabled ? "Disable Prime Premium" : "Enable Prime Premium";

    dom.selectedUserChatsCount.textContent = `${state.selectedUserChats.length}`;
    if (!state.selectedUserChats.length) {
      dom.selectedUserChatsList.innerHTML = `<div class="empty-state">No chats loaded for this user yet.</div>`;
    } else {
      dom.selectedUserChatsList.innerHTML = state.selectedUserChats
        .map((chat) => {
          const tags = buildChatTagMarkup(chat);
          return `
            <article class="entity-row${state.selectedChat?.id === chat.id ? " selected" : ""}">
              <div class="row-top">
                <div>
                  <div class="row-title">${escapeHtml(chatTitle(chat))}</div>
                  <div class="row-subtitle">${escapeHtml(chatSubtitle(chat))}</div>
                </div>
                <div class="identity-tags">${tags}</div>
              </div>
              <div class="row-meta">
                <div class="row-stats">${escapeHtml(chatTypeLabel(chat))}</div>
                <div class="row-stats">${escapeHtml(formatDateTime(chat.lastActivityAt))}</div>
              </div>
              <div class="row-actions">
                <button class="ghost-button" type="button" data-user-chat-id="${escapeHtml(chat.id)}">Open chat</button>
              </div>
            </article>
          `;
        })
        .join("");
    }
  }

  function renderCommunities() {
    const chats = filteredCommunities();
    if (!chats.length) {
      dom.communitiesList.innerHTML = `<div class="empty-state">No channels or communities match the current filter.</div>`;
      return;
    }

    dom.communitiesList.innerHTML = chats
      .map((chat) => {
        return `
          <article class="entity-row${state.selectedChat?.id === chat.id ? " selected" : ""}" data-community-chat-id="${escapeHtml(chat.id)}">
            <div class="row-top">
              <div>
                <div class="row-title">${escapeHtml(chatTitle(chat))}</div>
                <div class="row-subtitle">${escapeHtml(chat.communityDetails?.kind || "group")} · ${escapeHtml(chat.subtitle || "Prime Messaging space")}</div>
              </div>
              <div class="identity-tags">${buildChatTagMarkup(chat)}</div>
            </div>
            <div class="row-meta">
              <div class="row-stats">${escapeHtml(chat.lastMessagePreview || "No preview yet")}</div>
              <div class="row-stats">${escapeHtml(formatDateTime(chat.lastActivityAt))}</div>
            </div>
            <div class="row-actions">
              <button class="ghost-button" type="button">Inspect chat</button>
            </div>
          </article>
        `;
      })
      .join("");
  }

  function renderChatInspector() {
    const chat = state.selectedChat;
    if (!chat) {
      dom.chatPanelTitle.textContent = "Select a chat";
      dom.chatEmpty.classList.remove("hidden");
      dom.chatContent.classList.add("hidden");
      return;
    }

    dom.chatEmpty.classList.add("hidden");
    dom.chatContent.classList.remove("hidden");
    dom.chatPanelTitle.textContent = chatTitle(chat);
    dom.chatTitle.textContent = chatTitle(chat);
    dom.chatSubtitle.textContent = chatSubtitle(chat);
    dom.chatTags.innerHTML = buildChatTagMarkup(chat);

    const meta = [
      `Mode: ${escapeHtml(chat.mode || "online")}`,
      `Type: ${escapeHtml(chat.type || "direct")}`,
      `Participants: ${formatNumber(Array.isArray(chat.participantIDs) ? chat.participantIDs.length : 0)}`,
      `Last activity: ${escapeHtml(formatDateTime(chat.lastActivityAt))}`,
    ];
    dom.chatMeta.innerHTML = meta.join("<br />");

    dom.toggleChatOfficialButton.disabled = !isVerifiableCommunity(chat) || state.busy.chat;
    dom.toggleChatOfficialButton.textContent = chat.communityDetails?.isOfficial
      ? "Remove official badge"
      : "Set official badge";

    const canBlock = chat.type === "group";
    dom.toggleChatBlockButton.disabled = !canBlock || state.busy.chat;
    dom.toggleChatBlockButton.textContent = chat.communityDetails?.isBlockedByAdmin
      ? "Unblock chat"
      : "Block chat";
    dom.deleteChatButton.disabled = state.busy.chat;

    if (!state.selectedChatMessages.length) {
      dom.chatMessagesList.innerHTML = `<div class="empty-state">No messages loaded for this chat.</div>`;
      return;
    }

    dom.chatMessagesList.innerHTML = state.selectedChatMessages
      .map((message) => renderChatInspectorMessage(message))
      .join("");
  }

  function renderStatuses() {
    dom.authStatus.textContent = state.status.auth || "";
    dom.accessStatus.textContent = state.status.access || "";
    dom.maintenanceStatus.textContent = state.status.maintenance || "";
    dom.createUserStatus.textContent = state.status.createUser || "";
    dom.updatePolicyStatus.textContent = state.status.updatePolicy || "";
    dom.usersStatus.textContent = state.status.users || "";
    dom.selectedUserStatus.textContent = state.status.selectedUser || "";
    dom.communitiesStatus.textContent = state.status.communities || "";
    dom.chatStatus.textContent = state.status.chat || "";
    dom.broadcastStatus.textContent = state.status.broadcast || "";
  }

  function renderBusyStates() {
    dom.loginSubmit.disabled = state.busy.auth;
    dom.loginIdentifier.disabled = state.busy.auth;
    dom.loginPassword.disabled = state.busy.auth;
    dom.loginAdminLogin.disabled = state.busy.auth;
    dom.loginAdminPassword.disabled = state.busy.auth;
    dom.apiBaseInput.disabled = state.busy.auth;

    dom.saveAccessButton.disabled = state.busy.access || state.busy.dashboard;
    dom.adminLoginInput.disabled = state.busy.access || state.busy.dashboard;
    dom.adminPasswordInput.disabled = state.busy.access || state.busy.dashboard;
    dom.cleanupLegacyButton.disabled = state.busy.maintenance || state.busy.dashboard;
    dom.bulkDeleteFilteredButton.disabled =
      state.busy.maintenance || state.busy.dashboard || !state.users.some(canDeleteUser);

    dom.createUserButton.disabled = state.busy.createUser || state.busy.dashboard;
    dom.createDisplayNameInput.disabled = state.busy.createUser || state.busy.dashboard;
    dom.createUsernameInput.disabled = state.busy.createUser || state.busy.dashboard;
    dom.createPasswordInput.disabled = state.busy.createUser || state.busy.dashboard;

    dom.saveUpdatePolicyButton.disabled = state.busy.updatePolicy || state.busy.dashboard;
    dom.softPromptUpdateButton.disabled = state.busy.updatePolicy || state.busy.dashboard;
    dom.requireLatestUpdateButton.disabled = state.busy.updatePolicy || state.busy.dashboard;
    dom.resetUpdatePolicyButton.disabled = state.busy.updatePolicy || state.busy.dashboard;
    dom.updateLatestVersionInput.disabled = state.busy.updatePolicy || state.busy.dashboard;
    dom.updateMinimumVersionInput.disabled = state.busy.updatePolicy || state.busy.dashboard;
    dom.updateAppStoreURLInput.disabled = state.busy.updatePolicy || state.busy.dashboard;
    dom.updateTitleInput.disabled = state.busy.updatePolicy || state.busy.dashboard;
    dom.updateMessageInput.disabled = state.busy.updatePolicy || state.busy.dashboard;
    dom.updateRequiredTitleInput.disabled = state.busy.updatePolicy || state.busy.dashboard;
    dom.updateRequiredMessageInput.disabled = state.busy.updatePolicy || state.busy.dashboard;

    dom.refreshDashboardButton.disabled = state.busy.dashboard;
    dom.usersRefreshButton.disabled = state.busy.users || state.busy.dashboard;
    dom.selectedUserRefreshButton.disabled = state.busy.selectedUser || !state.selectedUser;
    dom.communitiesRefreshButton.disabled = state.busy.communities || state.busy.dashboard;
    dom.chatRefreshButton.disabled = state.busy.chat || !state.selectedChat;
    dom.broadcastSendButton.disabled = state.busy.broadcast;
  }

  function filteredCommunities() {
    const query = state.communitySearch;
    return state.communities.filter((chat) => {
      const kind = normalizeString(chat.communityDetails?.kind) || "group";
      if (state.communityFilter !== "all" && kind !== state.communityFilter) {
        return false;
      }
      if (!query) {
        return true;
      }
      const haystack = [chat.title, chat.subtitle, chat.lastMessagePreview, kind]
        .filter(Boolean)
        .join(" ")
        .toLowerCase();
      return haystack.includes(query);
    });
  }

  function buildChatTagMarkup(chat) {
    const tags = [];
    if (chat.communityDetails?.kind) {
      tags.push(`<span>${escapeHtml(chat.communityDetails.kind)}</span>`);
    }
    if (chat.communityDetails?.isOfficial) {
      tags.push(`<span class="tag official">OFFICIAL</span>`);
    }
    if (chat.communityDetails?.isBlockedByAdmin) {
      tags.push(`<span class="tag blocked">BLOCKED</span>`);
    }
    return tags.join("");
  }

  function chatTitle(chat) {
    return normalizeString(chat?.title) || "Untitled chat";
  }

  function chatSubtitle(chat) {
    return normalizeString(chat?.subtitle)
      || normalizeString(chat?.lastMessagePreview)
      || `${Array.isArray(chat?.participantIDs) ? chat.participantIDs.length : 0} participants`;
  }

  function chatTypeLabel(chat) {
    const kind = normalizeString(chat?.communityDetails?.kind);
    if (kind) {
      return `${kind} · ${normalizeString(chat?.mode) || "online"}`;
    }
    return `${normalizeString(chat?.type) || "direct"} · ${normalizeString(chat?.mode) || "online"}`;
  }

  function isVerifiableCommunity(chat) {
    const kind = normalizeString(chat?.communityDetails?.kind);
    return kind === "channel" || kind === "community";
  }

  function messageBody(message) {
    const text = normalizeString(message?.text);
    if (text) {
      return text;
    }
    switch (normalizeString(message?.kind)) {
      case "photo":
        return "Photo";
      case "video":
        return "Video";
      case "audio":
        return "Audio";
      case "voice":
        return "Voice message";
      case "document":
        return "Document";
      case "contact":
        return "Contact";
      case "location":
        return "Location";
      case "liveLocation":
        return "Live location";
      case "system":
        return "System message";
      default:
        return "Message";
    }
  }

  function renderChatInspectorMessage(message) {
    const outgoing =
      state.chatFocusUserId &&
      normalizeString(message.senderID) === normalizeString(state.chatFocusUserId);
    const senderName = normalizeString(message.senderDisplayName) || normalizeString(message.senderID) || "Unknown sender";
    const text = normalizeString(message?.text);
    const textHtml = text
      ? `<div class="message-text">${escapeHtml(text).replace(/\n/g, "<br />")}</div>`
      : "";

    return `
      <article class="message-card${outgoing ? " outgoing" : ""}">
        <div class="message-meta">
          <span class="message-sender">${escapeHtml(senderName)}</span>
          <span class="message-time">${escapeHtml(formatDateTime(message.createdAt))}</span>
        </div>
        <div class="message-body">
          ${textHtml}
          ${renderChatInspectorAttachments(message)}
          ${renderChatInspectorVoiceMessage(message?.voiceMessage)}
          ${!text && !message?.attachments?.length && !message?.voiceMessage
            ? `<div class="message-text">${escapeHtml(messageBody(message))}</div>`
            : ""}
        </div>
      </article>
    `;
  }

  function renderChatInspectorAttachments(message) {
    if (!Array.isArray(message?.attachments) || !message.attachments.length) {
      return "";
    }
    return `
      <div class="attachment-grid">
        ${message.attachments.map((attachment) => renderChatInspectorAttachment(attachment)).join("")}
      </div>
    `;
  }

  function renderChatInspectorAttachment(attachment) {
    const type = normalizeString(attachment?.type).toLowerCase() || "document";
    const url = safeUrl(attachment?.remoteURL);
    const escapedUrl = url ? escapeHtml(url) : "";
    const fileName = escapeHtml(normalizeString(attachment?.fileName) || fallbackAttachmentTitle(type));
    const size = formatBytes(attachment?.byteSize || 0);
    const meta = [attachmentKindLabel(type), size].filter(Boolean).join(" · ");

    if (type === "photo" && url) {
      return `
        <a class="message-attachment message-attachment-media" href="${escapedUrl}" target="_blank" rel="noreferrer">
          <img src="${escapedUrl}" alt="${fileName}" loading="lazy" />
          <div class="message-attachment-copy">
            <strong>${fileName}</strong>
            <span class="message-attachment-meta">${escapeHtml(meta)}</span>
          </div>
        </a>
      `;
    }

    if (type === "video" && url) {
      return `
        <div class="message-attachment message-attachment-media">
          <video src="${escapedUrl}" controls preload="metadata"></video>
          <div class="message-attachment-copy">
            <strong>${fileName}</strong>
            <span class="message-attachment-meta">${escapeHtml(meta)}</span>
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
            <span class="message-attachment-meta">${escapeHtml(meta)}</span>
          </div>
        </div>
      `;
    }

    return `
      <a class="message-attachment" href="${escapedUrl || "#"}" ${url ? 'target="_blank" rel="noreferrer"' : ""}>
        <div class="message-attachment-icon">${escapeHtml(attachmentIcon(type))}</div>
        <div class="message-attachment-copy">
          <strong>${fileName}</strong>
          <span class="message-attachment-meta">${escapeHtml(meta)}</span>
        </div>
      </a>
    `;
  }

  function renderChatInspectorVoiceMessage(voiceMessage) {
    const url = safeUrl(voiceMessage?.remoteFileURL);
    if (!voiceMessage || !url) {
      return "";
    }

    return `
      <div class="message-attachment voice-attachment">
        <audio src="${escapeHtml(url)}" controls preload="metadata"></audio>
        <div class="message-attachment-copy">
          <strong>Voice message</strong>
          <span class="message-attachment-meta">${escapeHtml(formatDuration(voiceMessage.durationSeconds || 0))}${voiceMessage.byteSize ? ` · ${escapeHtml(formatBytes(voiceMessage.byteSize))}` : ""}</span>
        </div>
      </div>
    `;
  }

  function fallbackAttachmentTitle(type) {
    switch (type) {
      case "photo":
        return "Photo";
      case "video":
        return "Video";
      case "audio":
        return "Audio";
      case "document":
        return "Document";
      case "contact":
        return "Contact";
      case "location":
        return "Location";
      default:
        return "Attachment";
    }
  }

  function attachmentKindLabel(type) {
    switch (type) {
      case "photo":
        return "Photo";
      case "video":
        return "Video";
      case "audio":
        return "Audio";
      case "document":
        return "Document";
      case "contact":
        return "Contact";
      case "location":
        return "Location";
      default:
        return "Attachment";
    }
  }

  function attachmentIcon(type) {
    switch (type) {
      case "photo":
        return "🖼️";
      case "video":
        return "🎬";
      case "audio":
        return "🎵";
      case "document":
        return "📄";
      case "contact":
        return "👤";
      case "location":
        return "📍";
      default:
        return "📎";
    }
  }

  function findUserInList(username) {
    return state.users.find((user) => normalizeUsername(user.username) === normalizeUsername(username));
  }

  function replaceUserInList(updatedUser) {
    state.users = state.users.map((user) => (user.id === updatedUser.id ? { ...user, ...updatedUser } : user));
  }

  function replaceChatEverywhere(updatedChat) {
    state.communities = state.communities.map((chat) => (chat.id === updatedChat.id ? updatedChat : chat));
    state.selectedUserChats = state.selectedUserChats.map((chat) => (chat.id === updatedChat.id ? updatedChat : chat));
  }

  function removeChatEverywhere(chatId) {
    state.communities = state.communities.filter((chat) => chat.id !== chatId);
    state.selectedUserChats = state.selectedUserChats.filter((chat) => chat.id !== chatId);
  }

  function canDeleteUser(user) {
    return normalizeUsername(user?.username) !== ADMIN_USERNAME;
  }

  function isUserBanned(user) {
    if (!user?.bannedUntil) {
      return false;
    }
    const timestamp = Date.parse(user.bannedUntil);
    return Number.isFinite(timestamp) && timestamp > Date.now();
  }

  function onLogoutClick() {
    clearSession();
    setConnectionState("idle");
    showAuthScreen();
    renderAll();
    setStatus("auth", "You have been signed out.");
  }

  function setStatus(key, message) {
    state.status[key] = message || "";
    renderStatuses();
  }

  function setBusy(key, value) {
    state.busy[key] = Boolean(value);
    renderBusyStates();
  }

  function normalizeApiBase(value) {
    return normalizeString(value).replace(/\/+$/, "");
  }

  function normalizeString(value) {
    return String(value == null ? "" : value).trim();
  }

  function normalizeUsername(value) {
    const trimmed = normalizeString(value).toLowerCase();
    return trimmed.startsWith("@") ? trimmed.slice(1) : trimmed;
  }

  function formatDateTime(value) {
    const date = new Date(value);
    if (Number.isNaN(date.getTime())) {
      return "unknown";
    }
    return new Intl.DateTimeFormat("en-GB", {
      dateStyle: "medium",
      timeStyle: "short",
    }).format(date);
  }

  function formatNumber(value) {
    const number = Number(value || 0);
    return Number.isFinite(number) ? new Intl.NumberFormat("en-US").format(number) : "0";
  }

  function formatBytes(value) {
    const number = Number(value || 0);
    if (!Number.isFinite(number) || number <= 0) {
      return "";
    }
    const units = ["B", "KB", "MB", "GB", "TB"];
    let size = number;
    let unitIndex = 0;
    while (size >= 1024 && unitIndex < units.length - 1) {
      size /= 1024;
      unitIndex += 1;
    }
    const digits = size >= 100 || unitIndex === 0 ? 0 : 1;
    return `${size.toFixed(digits)} ${units[unitIndex]}`;
  }

  function formatDuration(value) {
    const seconds = Math.max(0, Number(value || 0));
    const whole = Number.isFinite(seconds) ? Math.round(seconds) : 0;
    const minutesPart = Math.floor(whole / 60);
    const secondsPart = whole % 60;
    return `${minutesPart}:${String(secondsPart).padStart(2, "0")}`;
  }

  function safeUrl(value) {
    const raw = normalizeString(value);
    if (!raw) {
      return "";
    }
    try {
      const url = new URL(raw, window.location.origin);
      if (url.protocol === "http:" || url.protocol === "https:") {
        return url.toString();
      }
    } catch (error) {
      return "";
    }
    return "";
  }

  function escapeHtml(value) {
    return String(value == null ? "" : value)
      .replace(/&/g, "&amp;")
      .replace(/</g, "&lt;")
      .replace(/>/g, "&gt;")
      .replace(/"/g, "&quot;")
      .replace(/'/g, "&#39;");
  }

  function humanizeApiError(error, fallbackMessage) {
    const rawCode = normalizeString(error?.payload?.error || error?.message);
    const byCode = {
      admin_not_configured: "Admin login and password are not configured on the server.",
      admin_credentials_required: "Admin login or password is missing.",
      admin_token_required: "Admin token is required by the server.",
      admin_forbidden: "Admin credentials are invalid.",
      admin_auth_required: "Sign in to your @mihran account first, then open the admin console again.",
      admin_account_required: "This admin console is available only for @mihran.",
      admin_account_protected: "The @mihran admin account cannot be deleted from the admin console.",
      invalid_ban_duration: "Choose a valid ban duration.",
      invalid_username: "Use a valid username. Admin can create legacy usernames from 3 characters.",
      username_taken: "That username is already taken.",
      user_not_found: "User not found.",
      chat_not_found: "Chat not found.",
      invalid_group_chat: "Only channels and communities can be verified from the admin console.",
      chat_admin_blocked: "This chat is currently blocked by admin.",
      invalid_latest_version: "Enter a valid latest version.",
      minimum_version_above_latest: "Minimum supported version cannot be higher than the latest version.",
      broadcast_title_and_body_required: "Push title and body are required.",
      invalid_credentials: "The provided credentials are invalid.",
      invalid_session_payload: "The server returned an invalid session payload.",
      missing_session: "The browser session is missing or expired.",
      unauthorized: "The current session is not authorized anymore.",
    };
    return byCode[rawCode] || normalizeString(error?.message) || fallbackMessage;
  }
})();
