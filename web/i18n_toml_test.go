package web

import (
	"io/fs"
	"sort"
	"testing"

	"github.com/pelletier/go-toml/v2"
)

// TestTranslationsAreValidToml unmarshals every embedded translation file so a
// malformed key (e.g. a bad bulk-ops i18n insertion) fails here instead of silently
// breaking i18n at runtime.
func TestTranslationsAreValidToml(t *testing.T) {
	entries, err := fs.ReadDir(i18nFS, "translation")
	if err != nil {
		t.Fatal(err)
	}
	for _, e := range entries {
		data, err := i18nFS.ReadFile("translation/" + e.Name())
		if err != nil {
			t.Fatalf("read %s: %v", e.Name(), err)
		}
		var m map[string]any
		if err := toml.Unmarshal(data, &m); err != nil {
			t.Errorf("%s: invalid TOML: %v", e.Name(), err)
		}
	}
}

func keySet(keys ...string) map[string]bool {
	m := make(map[string]bool, len(keys))
	for _, k := range keys {
		m[k] = true
	}
	return m
}

// knownMissing are en_US keys not yet translated in the other locales (the Core
// Settings + systemd-service panels + setup-required toasts added after the
// fork). They render via the English fallback in web/locale.I18n — readable, not
// blank — so they are tolerated here as a baseline. Shrink this list as
// translations land; TestTranslationKeyParity fails on any en-only key NOT in
// this set, so the gap can never grow silently.
var knownMissing = keySet(
	"pages.inbounds.opDelete", "pages.inbounds.bulkDeleteConfirm",
	"pages.inbounds.opFreeze", "pages.inbounds.opUnfreeze",
	"pages.inbounds.selectAllClients",
	"pages.inbounds.bulkAffected", "pages.inbounds.bulkSkipped",
	"pages.client.freeze", "pages.client.unfreeze", "pages.client.frozen",
	"pages.index.checkUpdate", "pages.index.upToDate", "pages.index.updateAvailable",
	"pages.index.updateNow", "pages.index.updateConfirm", "pages.index.updateStarted",
	"pages.index.updateDownloading", "pages.index.updateInstalling", "pages.index.updateRestarting",
	"pages.index.updateCancel", "pages.index.panelUpdate",
	"pages.index.updateCancelling",
	"pages.index.updateReleaseNotes", "pages.index.updateNoNotes",
	"pages.index.updateModalTitle", "pages.index.updateModalIntro",
	"pages.index.virtualized", "pages.index.virtYes", "pages.index.virtNo",
	"pages.index.panelLocation", "pages.index.panelLocationError",
	"pages.index.virtContainer",

	"pages.core.absent", "pages.core.actions", "pages.core.consoleTitle",
	"pages.core.cores", "pages.core.disabled", "pages.core.editConfig",
	"pages.core.enabled", "pages.core.hideLog", "pages.core.inbounds",
	"pages.core.initSetup", "pages.core.ipForward", "pages.core.iproute",
	"pages.core.kernelModules", "pages.core.loaded", "pages.core.logs",
	"pages.core.missing", "pages.core.nftables", "pages.core.noLogs",
	"pages.core.present", "pages.core.provisionDesc", "pages.core.reRunSetup",
	"pages.core.rebootConfirm", "pages.core.rebootDetails", "pages.core.rebootImpact",
	"pages.core.rebootLater", "pages.core.rebootModulesLabel", "pages.core.rebootNow",
	"pages.core.rebootPkgLabel", "pages.core.rebootTitle", "pages.core.rebootWhat",
	"pages.core.rebooting", "pages.core.rebootingDesc", "pages.core.refresh",
	"pages.core.restart", "pages.core.runSetup", "pages.core.setupDone",
	"pages.core.setupNeededDesc", "pages.core.setupNeededTitle", "pages.core.setupRunning",
	"pages.core.showLog", "pages.core.stateError", "pages.core.stateIdle",
	"pages.core.stateNotInstalled", "pages.core.stateRunning", "pages.core.stateStopped",
	"pages.core.status", "pages.core.stepDaemons", "pages.core.stepForward",
	"pages.core.stepIpsec", "pages.core.stepModules", "pages.core.stop",
	"pages.core.subtitle", "pages.core.system", "pages.core.title", "pages.core.backend",
	"pages.core.toasts.provisioned", "pages.core.toasts.rebooting",
	"pages.core.toasts.restarted", "pages.core.toasts.stopped", "pages.core.version",
	"pages.core.availableCoresTitle", "pages.core.availableCoresDesc",
	"pages.core.addCore", "pages.core.uninstallCore",
	"pages.core.checkAll", "pages.core.uncheckAll",
	"pages.core.installedTag", "pages.core.alreadyInstalled",
	"pages.core.hasInbounds", "pages.core.sharesWith", "pages.core.pickerEmpty",
	"pages.core.pickerSetupTitle", "pages.core.pickerSetupDesc",
	"pages.core.pickerAddTitle", "pages.core.pickerAddDesc",
	"pages.core.pickerUninstallTitle", "pages.core.pickerUninstallDesc",
	"pages.core.pickerInstall", "pages.core.pickerUninstall",
	"pages.core.uninstallRunning", "pages.core.uninstallDone",
	"pages.core.uninstallKept", "pages.core.toasts.uninstalled",
	"pages.core.uninstallConsoleTitle",
	"pages.inbounds.toasts.setupRequired", "pages.inbounds.toasts.setupRequiredOk",
	"pages.inbounds.toasts.setupRequiredTitle", "pages.inbounds.toasts.setupRequiredForProtocol",
	"pages.settings.service.apply", "pages.settings.service.autoRefresh",
	"pages.settings.service.enable", "pages.settings.service.enableDesc",
	"pages.settings.service.installed", "pages.settings.service.liveLog",
	"pages.settings.service.liveLogDesc", "pages.settings.service.loadDefault",
	"pages.settings.service.name", "pages.settings.service.nameDesc",
	"pages.settings.service.noLog", "pages.settings.service.noSystemd",
	"pages.settings.service.onBoot", "pages.settings.service.start",
	"pages.settings.service.startDesc", "pages.settings.service.status",
	"pages.settings.service.statusDesc", "pages.settings.service.unit",
	"pages.settings.service.unitDesc", "pages.settings.serviceSettings",

	"pages.resellers.deleteHasAccounts", "pages.resellers.deleteKeep",
	"pages.resellers.deleteKeepDesc", "pages.resellers.deleteCascade",
	"pages.resellers.deleteCascadeDesc",

	"pages.index.importForeignTitle", "pages.index.importForeignDesc",
	"pages.index.importForeignConfirm",

	"pages.xray.outbound.sshOutHint", "pages.xray.outbound.sshOutNone",
	"pages.xray.outbound.sshOutAdd", "pages.xray.outbound.sshOutTag",
	"pages.xray.outbound.sshOutSocksPort", "pages.xray.outbound.sshOutAddress",
	"pages.xray.outbound.sshOutPort", "pages.xray.outbound.sshOutUsername",
	"pages.xray.outbound.sshOutAuth", "pages.xray.outbound.sshOutPassword",
	"pages.xray.outbound.sshOutKey", "pages.xray.outbound.sshOutKeep",
	"pages.xray.outbound.sshOutPassphrase", "pages.xray.outbound.sshOutKnownHost",
	"pages.xray.outbound.sshOutStatus", "pages.xray.outbound.sshOutUp",
	"pages.xray.outbound.sshOutDown", "pages.xray.outbound.sshOutSaved",

	// Tunnel management panel (merged tunnel-manager). Translated in en_US and
	// fa_IR; the other locales render via the English fallback until translated.
	"menu.tunnel",
	"pages.tunnel.title", "pages.tunnel.subtitle", "pages.tunnel.add",
	"pages.tunnel.create", "pages.tunnel.refresh", "pages.tunnel.optimize",
	"pages.tunnel.optimizeApply", "pages.tunnel.optimizeRevert", "pages.tunnel.optimizeState",
	"pages.tunnel.total", "pages.tunnel.up", "pages.tunnel.down", "pages.tunnel.empty",
	"pages.tunnel.protocol", "pages.tunnel.role", "pages.tunnel.roleForeign",
	"pages.tunnel.roleIran", "pages.tunnel.peer", "pages.tunnel.peerIp",
	"pages.tunnel.autostart", "pages.tunnel.traffic", "pages.tunnel.rate",
	"pages.tunnel.latency", "pages.tunnel.start", "pages.tunnel.stop",
	"pages.tunnel.restart", "pages.tunnel.logs", "pages.tunnel.edit",
	"pages.tunnel.remove", "pages.tunnel.removeConfirm", "pages.tunnel.name",
	"pages.tunnel.mtu", "pages.tunnel.advanced", "pages.tunnel.advancedHint",
	"pages.tunnel.addField", "pages.tunnel.save", "pages.tunnel.noEditable",
	"pages.tunnel.noLogs", "pages.tunnel.notInstalledTitle", "pages.tunnel.notInstalledDesc",
	"pages.tunnel.toasts.loadFailed", "pages.tunnel.toasts.created",
	"pages.tunnel.toasts.createFailed", "pages.tunnel.toasts.removed",
	"pages.tunnel.toasts.started", "pages.tunnel.toasts.stopped",
	"pages.tunnel.toasts.restarted", "pages.tunnel.toasts.enabled",
	"pages.tunnel.toasts.disabled", "pages.tunnel.toasts.saved",
	"pages.tunnel.toasts.saveFailed", "pages.tunnel.toasts.removedOnNodes", "pages.tunnel.toasts.updateFailed",
	"pages.tunnel.update", "pages.tunnel.updateConfirm",
	"pages.tunnel.updateDone", "pages.tunnel.updateNone",
	"pages.tunnel.autoGen", "pages.tunnel.mtuHint", "pages.tunnel.node.setupTunnel",
	"pages.tunnel.addPort", "pages.tunnel.checkPorts", "pages.tunnel.checkPortsNone",
	"pages.tunnel.deployTo", "pages.tunnel.deployLocal", "pages.tunnel.deployLocalHint",
	"pages.tunnel.deployPairHint", "pages.tunnel.noNodesWarn", "pages.tunnel.toasts.pairCreated",
	"pages.tunnel.node.title", "pages.tunnel.node.subtitle", "pages.tunnel.node.add",
	"pages.tunnel.node.name", "pages.tunnel.node.created", "pages.tunnel.node.oneliner",
	"pages.tunnel.node.onelinerHint", "pages.tunnel.node.online", "pages.tunnel.node.offline",
	"pages.tunnel.node.remoteIp", "pages.tunnel.node.lastSeen", "pages.tunnel.node.never",
	"pages.tunnel.node.viewTunnels", "pages.tunnel.node.remove", "pages.tunnel.node.removeConfirm",
	"pages.tunnel.node.empty", "pages.tunnel.node.execFailed",
	"pages.tunnel.node.setupTitle", "pages.tunnel.node.setupHint", "pages.tunnel.node.setupNone",
	"pages.inbounds.server", "pages.inbounds.serverLocal", "pages.inbounds.serverNodeHint",
	"pages.tunnel.locatedOn", "pages.tunnel.editingHalf",
	"pages.tunnel.foreignSide", "pages.tunnel.foreignSideLocal",
	"pages.tunnel.foreignSideLocalHint", "pages.tunnel.foreignSideNodeHint",
	"pages.tunnel.node.role", "pages.tunnel.node.roleIran", "pages.tunnel.node.roleForeign",
	"pages.tunnel.node.roleIranHint", "pages.tunnel.node.roleForeignHint",
	"pages.tunnel.node.foreignSetupHint",

	// Combined accounts (one customer across OpenVPN/L2TP/VLESS on one shared
	// allowance). Translated in en_US and fa_IR; the other locales render via the
	// English fallback until translated.
	"pages.combined.open", "pages.combined.title", "pages.combined.submit",
	"pages.combined.desc", "pages.combined.name", "pages.combined.nameDesc",
	"pages.combined.accounts", "pages.combined.allowance",
	"pages.combined.noInbounds", "pages.combined.sharedQuotaDesc", "pages.combined.sharedExpiryDesc",
	"pages.combined.subIdDesc",
	"pages.combined.created", "pages.combined.needName", "pages.combined.needProtocol",
	"pages.combined.sharedWith", "pages.combined.ownUsage", "pages.combined.groupTagDesc",
	"pages.combined.delayedStartDesc",
	"pages.combined.count", "pages.combined.countDesc",
	"pages.combined.addSlot", "pages.combined.removeSlot",
	"pages.combined.duplicateSlot", "pages.combined.slotInbound",
	"pages.combined.slotInboundDesc", "pages.combined.duplicateEmail",
	"pages.combinedEdit.newAccount", "pages.combinedEdit.removeAccount",
	"pages.client.addAnotherAccount",

	// The customer editor.
	"pages.combinedEdit.title", "pages.combinedEdit.desc",
	"pages.combinedEdit.daysDesc", "pages.combinedEdit.enableDesc",
	"pages.combinedEdit.needEmail",

	// The cross-inbound Clients page. Translated in en_US and fa_IR; the other
	// locales render via the English fallback until translated.
	"menu.clients",
	"pages.clients.title", "pages.clients.searchPlaceholder",
	"pages.clients.allProtocols", "pages.clients.allStates",
	"pages.clients.onlyGrouped", "pages.clients.statAccounts",
	"pages.clients.statCustomers", "pages.clients.colClient",
	"pages.clients.colCustomer", "pages.clients.colProtocol",
	"pages.clients.colInbound", "pages.clients.empty",
	"pages.clients.data", "pages.clients.exportJson", "pages.clients.importJson",
	"pages.clients.importBadFile", "pages.clients.importNoTarget",
	"pages.clients.importSkipped", "pages.clients.renew", "pages.clients.ended",
	"pages.inbounds.realityScan", "pages.inbounds.realityScanDesc", "pages.inbounds.realityScanCheck", "pages.inbounds.realityScanFind", "pages.inbounds.realityScanUse", "pages.inbounds.realityScanOk", "pages.inbounds.realityScanBad", "pages.inbounds.realityScanNoTarget", "pages.inbounds.realityScanNone", "pages.inbounds.toasts.scanRealityTargetError", "pages.inbounds.toasts.create",
	"pages.clients.pickGroup", "pages.clients.saveGroupFirst",
	"pages.clients.addAccount", "pages.clients.removeFromGroup",
	"pages.clients.colActions", "pages.clients.allGroups", "pages.clients.groups",
	"pages.clients.noGroups", "pages.clients.editGroup", "pages.clients.groupMembers",
	"pages.clients.groupDaysDesc", "pages.clients.deleteGroupConfirm",
	"pages.clients.selected", "pages.clients.clearSelection",
	"pages.clients.assignGroup", "pages.clients.assignGroupDesc",
	"pages.clients.noGroup", "pages.clients.newGroup",

	// The post-create connection-details sheet.
	"pages.credentials.title", "pages.credentials.headline",
	"pages.credentials.copyAll", "pages.credentials.server",
	"pages.credentials.port", "pages.credentials.alsoL2tp",
	"pages.credentials.alsoL2tpValue", "pages.credentials.ipsecPsk",
	"pages.credentials.config", "pages.credentials.subscription",
	"pages.credentials.subscriptionJson", "pages.credentials.show",
	"pages.credentials.headlineMany", "pages.credentials.headlineExisting",
	"pages.credentials.configFile", "pages.credentials.configFileHint",
	"pages.credentials.copyTelegram",

	// The rebuilt subscriber-facing page.
	"subscription.expired", "subscription.depleted", "subscription.daysLeft",
	"subscription.feedRaw", "subscription.desktop", "subscription.copyLink",
	"subscription.showQr", "subscription.hideQr", "subscription.scanQr",
	"subscription.addToApp", "subscription.addToAppDesc",
	"subscription.accounts", "subscription.accountsDesc",
	"subscription.copyAccounts",
)

// flattenKeys collapses nested TOML tables into dotted keys (e.g. "pages.core.title").
func flattenKeys(prefix string, m map[string]any, out map[string]bool) {
	for k, v := range m {
		key := k
		if prefix != "" {
			key = prefix + "." + k
		}
		if sub, ok := v.(map[string]any); ok {
			flattenKeys(key, sub, out)
		} else {
			out[key] = true
		}
	}
}

func loadTranslationKeys(t *testing.T, name string) map[string]bool {
	t.Helper()
	data, err := i18nFS.ReadFile("translation/" + name)
	if err != nil {
		t.Fatalf("read %s: %v", name, err)
	}
	var m map[string]any
	if err := toml.Unmarshal(data, &m); err != nil {
		t.Fatalf("%s: invalid TOML: %v", name, err)
	}
	keys := make(map[string]bool)
	flattenKeys("", m, keys)
	return keys
}

// TestTranslationKeyParity fails when any locale is missing an en_US key that is
// not in the knownMissing baseline — i.e. someone added an English-only string.
// Without this guard such a key renders blank (or English-fallback) for every
// non-English user and nobody notices. Fix a failure by translating the key in
// every locale, or (if intentionally deferred) adding it to knownMissing.
func TestTranslationKeyParity(t *testing.T) {
	const ref = "translate.en_US.toml"
	refKeys := loadTranslationKeys(t, ref)

	entries, err := fs.ReadDir(i18nFS, "translation")
	if err != nil {
		t.Fatal(err)
	}
	for _, e := range entries {
		if e.IsDir() || e.Name() == ref {
			continue
		}
		locKeys := loadTranslationKeys(t, e.Name())
		var newlyMissing []string
		for k := range refKeys {
			if !locKeys[k] && !knownMissing[k] {
				newlyMissing = append(newlyMissing, k)
			}
		}
		if len(newlyMissing) > 0 {
			sort.Strings(newlyMissing)
			t.Errorf("%s: %d en_US key(s) missing and not baselined "+
				"(translate them or add to knownMissing): %v",
				e.Name(), len(newlyMissing), newlyMissing)
		}
	}
}
