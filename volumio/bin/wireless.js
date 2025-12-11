#!/usr/bin/env node

//===================================================================
// Volumio Network Manager
// Original Copyright: Michelangelo Guarise - Volumio.org
// Maintainer: Just a Nerd
// Volumio Wireless Daemon - Version 4.0-rc3
// Maintainer: Development Team
// 
// RELEASE CANDIDATE 3 - DHCP Reconnection Fix
// 
// Major Changes in v4.0:
// - Single Network Mode (SNM) with ethernet/WiFi coordination
// - Emergency hotspot fallback when no network available
// - Improved transition handling and state management
// - Fixed deadlock and infinite loop issues
// - Enhanced logging and diagnostics
//
// RC3 Changes (DHCP Reconnection Fix):
// - Release DHCP lease before ethernet transition (prevents stale lease)
// - Force fresh DHCP request on WiFi reconnect (prevents rebind timeout)
// - Eliminates 50-second DHCP timeout after ethernet unplug
// - Fixes WiFi reconnection failure causing hotspot fallback
// - Add reconnectWiFiAfterEthernet() for fast WiFi reconnection
// - Rewrite checkWiredNetworkStatus() with carrier check
//
//===================================================================

// ===================================================================
// TIMEOUT CONSTANTS - Single source of truth for all timeout values
// ===================================================================
var EXEC_TIMEOUT_SHORT = 2000;      // General command execution (2s)
var EXEC_TIMEOUT_MEDIUM = 3000;     // Medium operations like regdomain detection (3s)
var EXEC_TIMEOUT_LONG = 5000;       // Long operations like service restarts (5s)
var EXEC_TIMEOUT_SCAN = 10000;      // Network scanning for regdomain (10s)
var KILL_TIMEOUT = 5000;            // kill() timeout wrapper (5s)
var RECONNECT_WAIT = 3000;          // Wait for wpa_supplicant association (3s)
var USB_SETTLE_WAIT = 2000;         // USB WiFi adapter settle time (2s)
var HOTSPOT_RETRY_DELAY = 3000;     // Hotspot fallback retry delay (3s)
var STARTAP_RETRY_DELAY = 2000;     // startAP retry delay (2s)
var INTERFACE_CHECK_INTERVAL = 500; // Interface ready polling interval (500ms)
var INTERFACE_READY_TIMEOUT = 8000; // Max wait for interface to become ready (8s)

// ===================================================================
// COMMAND BINARIES - Single source of truth for all executable paths
// ===================================================================
var SUDO = "/usr/bin/sudo";
var IFCONFIG = "/sbin/ifconfig";
var IW = "/sbin/iw";
var IP = "/sbin/ip";
var DHCPCD = "/sbin/dhcpcd";
var SYSTEMCTL = "/bin/systemctl";
var IWGETID = "/sbin/iwgetid";
var WPA_CLI = "/sbin/wpa_cli";
var WPA_SUPPLICANT = "wpa_supplicant";
var PGREP = "pgrep";
var CAT = "cat";
var GREP = "grep";
var CUT = "cut";
var TR = "tr";

// ===================================================================
// FILE PATHS - Single source of truth for all file system paths
// ===================================================================
// System paths
var VOLUMIO_ENV = "/volumio/.env";
var OS_RELEASE = "/etc/os-release";
var CRDA_CONFIG = CRDA_CONFIG;
var WPA_SUPPLICANT_CONF = "/etc/wpa_supplicant/wpa_supplicant.conf";

// Data paths
var DATA_DIR = "/data";
var CONFIG_DIR = DATA_DIR + "/configuration";
var NET_CONFIGURED = CONFIG_DIR + "/netconfigured";
var WLAN_STATIC = CONFIG_DIR + "/wlanstatic";
var NETWORK_CONFIG = CONFIG_DIR + "/system_controller/network/config.json";
var WLAN_STATUS_FILE = DATA_DIR + "/wlan0status";
var ETH_STATUS_FILE = DATA_DIR + "/eth0status";
var SNM_STATUS_FILE = DATA_DIR + "/snm_status";  // Single Network Mode status for backend
var FLAG_DIR = DATA_DIR + "/flagfiles";
var WIRELESS_ESTABLISHED_FLAG = FLAG_DIR + "/wirelessEstablishedOnce";

// Temporary paths
var TMP_DIR = "/tmp";
var WIRELESS_LOG = TMP_DIR + "/wireless.log";
var FORCE_HOTSPOT_FLAG = TMP_DIR + "/forcehotspot";
var NETWORK_STATUS_FILE = TMP_DIR + "/networkstatus";  // Node notifier

// System paths
var SYS_CLASS_NET = "/sys/class/net";
var VOLUMIO_PLUGINS = "/volumio/app/plugins";
var IFCONFIG_LIB = VOLUMIO_PLUGINS + "/system_controller/network/lib/ifconfig.js";

// Time needed to settle some commands sent to the system like ifconfig
var debug = false;

var settleTime = 3000;
var fs = require('fs-extra')
var thus = require('child_process');
var wlan = "wlan0";
var eth = "eth0";
// var dhcpd = "dhcpd";
var dhclient = SUDO + " " + DHCPCD + " " + wlan;
var justdhclient = DHCPCD + ".*" + wlan;  // Pattern for killing wlan0 dhcpcd only
var starthostapd = SYSTEMCTL + " start hostapd.service";
var stophostapd = SYSTEMCTL + " stop hostapd.service";
var ifconfigHotspot = IFCONFIG + " " + wlan + " 192.168.211.1 up";
var ifconfigWlan = IFCONFIG + " " + wlan + " up";
var ifdeconfig = SUDO + " " + IP + " addr flush dev " + wlan + " && " + SUDO + " " + IFCONFIG + " " + wlan + " down";
var execSync = require('child_process').execSync;
var exec = require('child_process').exec;
var ifconfig = require(IFCONFIG_LIB);
var wirelessWPADriver = getWirelessWPADriverString();
var wpasupp = WPA_SUPPLICANT + " -s -B -D" + wirelessWPADriver + " -c" + WPA_SUPPLICANT_CONF + " -i" + wlan;
var wpasuppPattern = WPA_SUPPLICANT + ".*" + wlan;  // Pattern for killing wlan0 wpa_supplicant only
var restartdhcpcd = SUDO + " " + SYSTEMCTL + " restart dhcpcd.service";
var ifconfigUp = SUDO + " " + IFCONFIG + " " + wlan + " up";
var iwgetid = SUDO + " " + IWGETID + " -r";
var wpacli = WPA_CLI + " -i " + wlan;
var iwRegGet = SUDO + " " + IW + " reg get";
var iwScan = SUDO + " " + IW + " " + wlan + " scan";
var iwRegSet = SUDO + " " + IW + " reg set";
var iwList = IW + " list";
var ipLink = IP + " link show " + wlan;
var ipAddr = IP + " addr show " + wlan;
var checkInterfaceLink = "readlink " + SYS_CLASS_NET + "/" + wlan;
var singleNetworkMode = true;  // Default ON for production
var isWiredNetworkActive = false;
var currentEthStatus = 'disconnected';
var apStartInProgress = false;
var wirelessFlowInProgress = false;

// Global variables
var retryCount = 0;
var maxRetries = 3;
var wpaerr;
var lesstimer;
var totalSecondsForConnection = 30;
var pollingTime = 1;
var actualTime = 0;
var apstopped = 0
var transitionStartTime = 0;  // Track transition timing for diagnostics


if (process.argv.length < 2) {
    loggerInfo("Volumio Wireless Daemon. Use: start|stop");
} else {
    var args = process.argv[2];
    loggerDebug('WIRELESS DAEMON: ' + args);
    initializeWirelessDaemon();
    switch (args) {
        case "start":
            initializeWirelessFlow();
            break;
        case "stop":
            stopAP(function() {});
            break;
        case "test":
            wstatus("test");
            break;
    }
}

function initializeWirelessDaemon() {
    retrieveEnvParameters();
    startWiredNetworkingMonitor();
    if (debug) {
        var wpasupp = "wpa_supplicant -d -s -B -D" + wirelessWPADriver + " -c/etc/wpa_supplicant/wpa_supplicant.conf -i" + wlan;
    }
}

function kill(pattern, callback) {
    loggerDebug("kill(): Pattern: " + pattern);
    
    // Use pkill directly to avoid blocking in fs.watch() callback contexts
    var command = 'pkill -f "' + pattern + '"';
    
    // Timeout protection to prevent indefinite blocking
    var callbackFired = false;
    var timeoutHandle = setTimeout(function() {
        if (!callbackFired) {
            callbackFired = true;
            loggerInfo("WARNING: kill() timed out after " + (KILL_TIMEOUT/1000) + "s for: " + pattern);
            callback(new Error('Kill operation timeout'));
        }
    }, KILL_TIMEOUT);
    
    return thus.exec(command, function(err, stdout, stderr) {
        if (!callbackFired) {
            callbackFired = true;
            clearTimeout(timeoutHandle);
            
            // pkill returns 1 if no processes found - NOT an error
            // Since exec() doesn't give us direct access to exit code,
            // we treat ANY pkill error as "not found" (safe assumption)
            // pkill only fails if: no processes (1) or syntax error (2+)
            // Our patterns are static, so syntax errors won't happen in production
            if (err) {
                // Assume "no processes found" which is normal
                loggerDebug("kill(): No processes found: " + pattern);
                return callback(null);
            }
            
            loggerDebug("kill(): Success: " + pattern);
            callback(null);
        }
    });
}


function launch(fullprocess, name, sync, callback) {
    if (sync) {
        var child = thus.exec(fullprocess, {}, callback);
        child.stdout.on('data', function(data) {
            loggerDebug(name + 'stdout: ' + data);
        });

        child.stderr.on('data', function(data) {
            loggerDebug(name + 'stderr: ' + data);
        });

        child.on('close', function(code) {
            loggerDebug(name + 'child process exited with code ' + code);
        });
    } else {
        var all = fullprocess.split(" ");
        var process = all[0];
        if (all.length > 0) {
            all.splice(0, 1);
        }
        loggerDebug("launching " + process + " args: ");
        loggerDebug(all);
        var child = thus.spawn(process, all, {});
        child.stdout.on('data', function(data) {
            loggerDebug(name + 'stdout: ' + data);
        });

        child.stderr.on('data', function(data) {
            loggerDebug(name + 'stderr: ' + data);
        });

        child.on('close', function(code) {
            loggerDebug(name + 'child process exited with code ' + code);
        });
        callback();
    }

    return
}


function startHotspot(callback) {
    stopHotspot(function(err) {
        if (isHotspotDisabled()) {
            loggerInfo('Hotspot is disabled, not starting it');
            launch(ifconfigWlan, "configwlanup", true, function(err) {
                loggerDebug("ifconfig " + err);
                if (callback) callback();
            });
        } else {
            launch(ifconfigHotspot, "confighotspot", true, function(err) {
                loggerDebug("ifconfig " + err);
                launch(starthostapd,"hotspot" , false, function() {
                    updateNetworkState("hotspot");
                    if (callback) callback();
                });
            });
        }
    });
}

function startHotspotForce(callback) {
    stopHotspot(function(err) {
        loggerInfo('Starting Force Hotspot')
        launch(ifconfigHotspot, "confighotspot", true, function(err) {
            loggerDebug("ifconfig " + err);
            launch(starthostapd,"hotspot" , false, function() {
                updateNetworkState("hotspot");
                if (callback) callback();
            });
        });
    });
}

function stopHotspot(callback) {
    launch(stophostapd, "stophotspot" , true, function(err) {
        launch(ifdeconfig, "ifdeconfig", true, callback);
    });
}

function startAP(callback) {
    loggerInfo("Stopped hotspot (if there)..");
    launch(ifdeconfig, "ifdeconfig", true, function (err) {
        loggerDebug("Conf " + ifdeconfig);
        waitForWlanRelease(0, function () {
            launch(wpasupp, "wpa supplicant", false, function (err) {
                loggerDebug("wpasupp " + err);
                wpaerr = err ? 1 : 0;

                let staticDhcpFile;
                try {
                    staticDhcpFile = fs.readFileSync(WLAN_STATIC, 'utf8');
                    loggerInfo("FIXED IP via wlanstatic");
                } catch (e) {
                    staticDhcpFile = dhclient; // fallback
                    loggerInfo("DHCP IP fallback");
                }

                launch(staticDhcpFile, "dhclient", false, callback);
            });
        });
    });
}

// Wait for wlan0 interface to be down or released
function waitForWlanRelease(attempt, onReleased) {
    const MAX_RETRIES = 10;
    const RETRY_INTERVAL = 1000;

    try {
        const output = execSync('ip link show wlan0').toString();
        if (output.includes('state DOWN') || output.includes('NO-CARRIER')) {
            loggerDebug("wlan0 is released.");
            return onReleased();
        }
    } catch (e) {
        loggerDebug("Error checking wlan0: " + e);
        return onReleased(); // fallback if interface not found
    }

    if (attempt >= MAX_RETRIES) {
        loggerDebug("Timeout waiting for wlan0 release.");
        return onReleased();
    }

    setTimeout(function () {
        waitForWlanRelease(attempt + 1, onReleased);
    }, RETRY_INTERVAL);
}

function clearConnectionTimer() {
    if (lesstimer) {
        clearInterval(lesstimer);
        lesstimer = null;
        loggerDebug("Cleared connection timer");
    }
}

// ===================================================================
// STAGE 1 MODULES: INTERFACE IDENTITY & STATE TRACKING
// ===================================================================

// ===================================================================
// MODULE 1: UDEV COORDINATOR
// Synchronizes with udev rename operations and device initialization
// ===================================================================

// Wait for udev to complete all pending events
// Returns immediately if no events pending
function waitForUdevSettle(timeout, callback) {
    timeout = timeout || 10000; // 10 second default max wait
    var timeoutSeconds = Math.floor(timeout / 1000);
    
    loggerDebug("UdevCoordinator: Waiting for udev to settle (max " + timeoutSeconds + "s)");
    
    try {
        var startTime = Date.now();
        execSync('udevadm settle --timeout=' + timeoutSeconds, { 
            encoding: 'utf8', 
            timeout: timeout 
        });
        var elapsed = Date.now() - startTime;
        loggerDebug("UdevCoordinator: udev settled in " + elapsed + "ms");
        callback(null);
    } catch (e) {
        loggerInfo("UdevCoordinator: udev settle timeout or error: " + e);
        // Not fatal - proceed anyway, validation will catch issues
        callback(null);
    }
}

// Check if udev queue is empty (no pending events)
function isUdevQueueEmpty() {
    try {
        var result = execSync('udevadm settle --timeout=0', { encoding: 'utf8' });
        loggerDebug("UdevCoordinator: udev queue is empty");
        return true;
    } catch (e) {
        loggerDebug("UdevCoordinator: udev queue has pending events");
        return false;
    }
}

// ===================================================================
// MODULE 2: INTERFACE VALIDATOR
// Verifies interface physical identity and operational readiness
// ===================================================================

// Get current physical identity of wlan0 (MAC address)
// Returns null if interface doesn't exist
function getInterfaceMAC(interfaceName) {
    try {
        var mac = fs.readFileSync('/sys/class/net/' + interfaceName + '/address', 'utf8').trim();
        return mac;
    } catch (e) {
        loggerDebug("InterfaceValidator: Cannot read MAC for " + interfaceName + ": " + e);
        return null;
    }
}

// Get physical bus path (determines if USB or onboard)
// Returns path like "../../devices/platform/..." or null
function getInterfaceBusPath(interfaceName) {
    try {
        var linkPath = fs.readlinkSync('/sys/class/net/' + interfaceName).trim();
        return linkPath;
    } catch (e) {
        loggerDebug("InterfaceValidator: Cannot read bus path for " + interfaceName + ": " + e);
        return null;
    }
}

// Check if interface is USB device
function isInterfaceUSB(interfaceName) {
    var busPath = getInterfaceBusPath(interfaceName);
    if (!busPath) return false;
    return busPath.includes('usb');
}

// Get interface operational state flags
// Returns object with state information or null
function getInterfaceOperState(interfaceName) {
    try {
        var operstate = fs.readFileSync('/sys/class/net/' + interfaceName + '/operstate', 'utf8').trim();
        var flags = fs.readFileSync('/sys/class/net/' + interfaceName + '/flags', 'utf8').trim();
        var carrier = '0';
        try {
            carrier = fs.readFileSync('/sys/class/net/' + interfaceName + '/carrier', 'utf8').trim();
        } catch (e) {
            // Carrier file doesn't exist if interface is down
        }
        
        return {
            operstate: operstate,      // 'up', 'down', 'unknown', 'dormant'
            flags: parseInt(flags, 16), // Hex flags
            carrier: carrier === '1'    // Physical link present
        };
    } catch (e) {
        loggerDebug("InterfaceValidator: Cannot read operstate for " + interfaceName + ": " + e);
        return null;
    }
}

// Validate interface is ready for wpa_supplicant binding
// Checks: exists, driver loaded, not in use by other process
function validateInterfaceReady(interfaceName) {
    loggerDebug("InterfaceValidator: Validating " + interfaceName + " readiness");
    
    // Check interface exists
    var mac = getInterfaceMAC(interfaceName);
    if (!mac) {
        loggerInfo("InterfaceValidator: FAIL - " + interfaceName + " does not exist");
        return { ready: false, reason: 'interface_not_found' };
    }
    
    // Check operational state
    var state = getInterfaceOperState(interfaceName);
    if (!state) {
        loggerInfo("InterfaceValidator: FAIL - cannot read " + interfaceName + " state");
        return { ready: false, reason: 'state_unreadable' };
    }
    
    // Interface must not be 'unknown' - indicates driver issue
    if (state.operstate === 'unknown') {
        loggerInfo("InterfaceValidator: FAIL - " + interfaceName + " driver not initialized (operstate=unknown)");
        return { ready: false, reason: 'driver_not_ready' };
    }
    
    // Check if interface is being renamed (operstate would be 'down' during rename)
    // This is a heuristic - if interface just appeared and is already down, might be mid-rename
    var busPath = getInterfaceBusPath(interfaceName);
    loggerDebug("InterfaceValidator: " + interfaceName + " MAC=" + mac + " operstate=" + state.operstate + " USB=" + (busPath && busPath.includes('usb')));
    
    // Interface is ready
    loggerInfo("InterfaceValidator: READY - " + interfaceName + " is ready for operations");
    return { 
        ready: true, 
        mac: mac, 
        isUSB: busPath && busPath.includes('usb'),
        operstate: state.operstate 
    };
}

// Wait for interface to become ready with polling fallback
// This is a safety mechanism - should rarely be needed with udev settle
function waitForInterfaceReady(interfaceName, maxWaitMs, callback) {
    var startTime = Date.now();
    var attempts = 0;
    var maxAttempts = Math.floor(maxWaitMs / 500); // Check every 500ms
    
    loggerDebug("InterfaceValidator: Waiting for " + interfaceName + " to become ready (max " + (maxWaitMs/1000) + "s)");
    
    function checkReady() {
        attempts++;
        var validation = validateInterfaceReady(interfaceName);
        
        if (validation.ready) {
            var elapsed = Date.now() - startTime;
            loggerInfo("InterfaceValidator: " + interfaceName + " became ready after " + elapsed + "ms");
            return callback(null, validation);
        }
        
        if (attempts >= maxAttempts) {
            var elapsed = Date.now() - startTime;
            loggerInfo("InterfaceValidator: TIMEOUT waiting for " + interfaceName + " after " + elapsed + "ms (reason: " + validation.reason + ")");
            return callback(new Error('Timeout waiting for interface ready: ' + validation.reason), validation);
        }
        
        // Wait 500ms and check again
        setTimeout(checkReady, INTERFACE_CHECK_INTERVAL);
    }
    
    checkReady();
}

// Check if wlan0 is a USB WiFi adapter
// Returns true if USB, false if onboard or check fails
function isUsbWifiAdapter() {
    try {
        var linkPath = execSync(checkInterfaceLink, { encoding: 'utf8' }).trim();
        return linkPath.includes('usb');
    } catch (e) {
        loggerDebug("Could not determine if wlan0 is USB: " + e);
        return false;
    }
}

function stopAP(callback) {
    kill(justdhclient, function(err) {
        kill(wpasupp, function(err) {
            callback();
        });
    });
}

function startFlow() {
    // Prevent duplicate flow starts
    if (wirelessFlowInProgress) {
        loggerDebug("Wireless flow already in progress, ignoring duplicate call");
        return;
    }
    wirelessFlowInProgress = true;

    // Stop any existing flow first
    clearConnectionTimer();

    actualTime = 0;
    apstopped = 0;
    apStartInProgress = false;
    wpaerr = 0;

    try {
        var netconfigured = fs.statSync(NET_CONFIGURED);
    } catch (e) {
        var directhotspot = true;
    }

    try {
        fs.accessSync(FORCE_HOTSPOT_FLAG, fs.F_OK);
        var hotspotForce = true;
        fs.unlinkSync(FORCE_HOTSPOT_FLAG)
    } catch (e) {
        var hotspotForce = false;
    }
    if (hotspotForce) {
        loggerInfo('Wireless networking forced to hotspot mode');
        startHotspotForce(function () {
            notifyWirelessReady();
        });
    } else if (isWirelessDisabled()) {
        loggerInfo('Wireless Networking DISABLED, not starting wireless flow');
        notifyWirelessReady();
    } else if (singleNetworkMode && isWiredNetworkActive) {
        loggerInfo('Single Network Mode: Wired network active, not starting wireless flow');
        notifyWirelessReady();
    } else if (directhotspot){
        startHotspot(function () {
            notifyWirelessReady();
        });
    } else {
        loggerInfo("Start wireless flow");
        waitForInterfaceReleaseAndStartAP();
    }
}

function startHotspotFallbackSafe(retry = 0) {
    const hotspotMaxRetries = 3;

    function handleHotspotResult(err) {
        if (err) {
            loggerInfo(`Hotspot launch failed. Retry ${retry + 1} of ${hotspotMaxRetries}`);
            if (retry + 1 < hotspotMaxRetries) {
                setTimeout(() => startHotspotFallbackSafe(retry + 1), 3000);
            } else {
                loggerInfo("Hotspot failed after maximum retries. System remains offline.");
                notifyWirelessReady();
            }
            return;
        }

        // Verify hostapd status
        try {
            const hostapdStatus = execSync("systemctl is-active hostapd", { encoding: 'utf8' }).trim();
            if (hostapdStatus !== "active") {
                loggerInfo("Hostapd did not reach active state. Retrying fallback.");
                if (retry + 1 < hotspotMaxRetries) {
                    setTimeout(() => startHotspotFallbackSafe(retry + 1), 3000);
                } else {
                    loggerInfo("Hostapd failed after maximum retries. System remains offline.");
                    notifyWirelessReady();
                }
            } else {
                loggerInfo("Hotspot active and hostapd is running.");
                updateNetworkState("hotspot");
                notifyWirelessReady();
            }
        } catch (e) {
            loggerInfo("Error checking hostapd status: " + e.message);
            if (retry + 1 < hotspotMaxRetries) {
                setTimeout(() => startHotspotFallbackSafe(retry + 1), 3000);
            } else {
                loggerInfo("Could not confirm hostapd status. System remains offline.");
                notifyWirelessReady();
            }
        }
    }

    if (!isWirelessDisabled()) {
        if (checkConcurrentModeSupport()) {
            loggerInfo('Fallback: Concurrent AP+STA supported. Starting hotspot.');
            startHotspot(handleHotspotResult);
        } else {
            loggerInfo('Fallback: Stopping STA and starting hotspot.');
            stopAP(function () {
                setTimeout(() => {
                    startHotspot(handleHotspotResult);
                }, settleTime);
            });
        }
    } else {
        loggerInfo("Fallback: WiFi disabled. No hotspot started.");
        notifyWirelessReady();
    }
}

function stop(callback) {
    stopAP(function() {
        stopHotspot(callback);
    });
}

// Reconnect WiFi after ethernet disconnect in Single Network Mode
// Uses wpa_cli reconnect for fast transition without full flow restart
function reconnectWiFiAfterEthernet(callback) {
    loggerInfo("SNM: Ethernet disconnected, reconnecting WiFi");
    
    // Check if wpa_supplicant is running
    try {
        var wpaCheck = execSync(PGREP + " -f 'wpa_supplicant.*" + wlan + "'", { 
            encoding: 'utf8',
            timeout: EXEC_TIMEOUT_SHORT 
        });
        loggerDebug("reconnectWiFi: wpa_supplicant already running: " + wpaCheck.trim());
    } catch (e) {
        // wpa_supplicant not running, need to start it
        loggerInfo("reconnectWiFi: wpa_supplicant not running, starting full wireless flow");
        return initializeWirelessFlow();
    }
    
    // wpa_supplicant is running, just reconnect
    var reconnectCmd = wpacli + " reconnect";
    launch(reconnectCmd, "wpa_reconnect", true, function(err) {
        if (err) {
            loggerInfo("reconnectWiFi: Reconnect command failed: " + err);
            loggerInfo("reconnectWiFi: Falling back to full wireless flow restart");
            wirelessFlowInProgress = false;  // Reset to allow restart
            return initializeWirelessFlow();
        }
        
        loggerInfo("reconnectWiFi: WiFi reconnection triggered");
        
        // Wait for connection to establish before launching dhcpcd
        // Give wpa_supplicant time to associate and authenticate
        setTimeout(function() {
            // Check connection state
            try {
                var wpaState = execSync(wpacli + " status | " + GREP + " wpa_state", {
                    encoding: 'utf8',
                    timeout: EXEC_TIMEOUT_SHORT
                }).trim();
                
                loggerDebug("reconnectWiFi: WiFi state after reconnect: " + wpaState);
                
                if (wpaState.includes("COMPLETED")) {
                    loggerInfo("reconnectWiFi: WiFi reconnected successfully");
                    
                    // Check if this is a USB WiFi adapter
                    if (isUsbWifiAdapter()) {
                        // FIX v4.0-rc3: Use dhcpcd -n to force fresh lease instead of service restart
                        // Service restart may attempt to rebind old/expired lease which can fail or timeout
                        // The -n flag forces new DISCOVER/REQUEST cycle instead of rebind attempt
                        loggerInfo("reconnectWiFi: USB adapter detected, requesting fresh DHCP lease");
                        try {
                            var freshDhcpCmd = SUDO + ' ' + DHCPCD + ' -n ' + wlan;
                            execSync(freshDhcpCmd, { encoding: 'utf8', timeout: EXEC_TIMEOUT_LONG });
                            loggerDebug("reconnectWiFi: Fresh DHCP lease requested for " + wlan);
                        } catch (e) {
                            loggerInfo("reconnectWiFi: WARNING - Failed to request fresh DHCP: " + e);
                        }
                        setTimeout(function() {
                            // Calculate transition time for diagnostics
                            if (transitionStartTime > 0) {
                                var reconnectTime = Date.now() - transitionStartTime;
                                loggerInfo("SNM: WiFi reconnection completed in " + reconnectTime + "ms");
                                transitionStartTime = 0;
                            }
                            
                            loggerInfo("reconnectWiFi: WiFi reconnection complete with USB adapter");
                            updateNetworkState("ap");
                            restartAvahi();
                            if (callback) callback(null);
                        }, USB_SETTLE_WAIT);
                    } else {
                        // Launch dhcpcd to get IP address
                        let staticDhcpFile;
                        try {
                            staticDhcpFile = fs.readFileSync(WLAN_STATIC, 'utf8');
                            loggerInfo("reconnectWiFi: Using static IP configuration");
                        } catch (e) {
                            staticDhcpFile = dhclient;
                            loggerInfo("reconnectWiFi: Using DHCP for IP");
                        }
                        
                        launch(staticDhcpFile, "dhclient", false, function() {
                            // Calculate transition time for diagnostics
                            if (transitionStartTime > 0) {
                                var reconnectTime = Date.now() - transitionStartTime;
                                loggerInfo("SNM: WiFi reconnection completed in " + reconnectTime + "ms");
                                transitionStartTime = 0;
                            }
                            
                            loggerInfo("reconnectWiFi: WiFi reconnection complete, obtaining IP");
                            updateNetworkState("ap");
                            restartAvahi();
                            if (callback) callback(null);
                        });
                    }
                    
                } else {
                    loggerInfo("reconnectWiFi: WiFi reconnect incomplete (" + wpaState + "), reinitializing wireless flow");
                    wirelessFlowInProgress = false;  // Reset to allow restart
                    initializeWirelessFlow();
                }
                
            } catch (e) {
                loggerInfo("reconnectWiFi: Could not verify WiFi state: " + e);
                loggerInfo("reconnectWiFi: Falling back to full wireless flow");
                wirelessFlowInProgress = false;  // Reset to allow restart
                initializeWirelessFlow();
            }
            
        }, RECONNECT_WAIT); // Wait for wpa_supplicant association
    });
}

if ( ! fs.existsSync("/sys/class/net/" + wlan + "/operstate") ) {
    loggerInfo("No wireless interface, exiting");
    process.exit(0);
}

function initializeWirelessFlow() {
    loggerInfo("Wireless.js initializing wireless flow");
    loggerInfo("Cleaning previous...");
    stopHotspot(function () {
        stopAP(function() {
            loggerInfo("Stopped aP");
            // Here we set the regdomain if not set
            detectAndApplyRegdomain(function() {
                startFlow();
            });
        })});
}

function wstatus(nstatus) {
    thus.exec("echo " + nstatus + " >/tmp/networkstatus", null);
}

function updateNetworkState(state) {
    wstatus(state);
    refreshNetworkStatusFile();
}

function restartAvahi() {
    loggerInfo("Restarting avahi-daemon...");
    thus.exec("/bin/systemctl restart avahi-daemon", function (err, stdout, stderr) {
        if (err) {
            loggerInfo("Avahi restart failed: " + err);
        }
    });
}

function loggerDebug(msg) {
    if (debug) {
        console.log('WIRELESS.JS Debug: ' + msg)
    }
    writeToLogFile('DEBUG', msg);
}

function loggerInfo(msg) {
    console.log('WIRELESS.JS: ' + msg);
    writeToLogFile('INFO', msg);
}

function writeToLogFile(level, msg) {
    try {
        const timestamp = new Date().toISOString();
        fs.appendFileSync(WIRELESS_LOG, `[${timestamp}] ${level}: ${msg}\n`);
    } catch (e) {}
}

function refreshNetworkStatusFile() {
    try {
        fs.utimesSync(NETWORK_STATUS_FILE, new Date(), new Date());
    } catch (e) {
        loggerDebug("Failed to refresh /tmp/networkstatus timestamp: " + e.toString());
    }
}

function getWirelessConfiguration() {
    try {
        var conf = fs.readJsonSync(NETWORK_CONFIG);
        loggerDebug('Loaded configuration');
        loggerDebug('CONF: ' + JSON.stringify(conf));
    } catch (e) {
        loggerDebug('First boot');
        var conf = fs.readJsonSync(VOLUMIO_PLUGINS + '/system_controller/network/config.json');
    }
    return conf
}

function isHotspotDisabled() {
    var hotspotConf = getWirelessConfiguration();
    var hotspotDisabled = false;
    if (hotspotConf !== undefined && hotspotConf.enable_hotspot !== undefined && hotspotConf.enable_hotspot.value !== undefined && !hotspotConf.enable_hotspot.value) {
        hotspotDisabled = true;
    }
    return hotspotDisabled
}

function isWirelessDisabled() {
    var wirelessConf = getWirelessConfiguration();
    var wirelessDisabled = false;
    if (wirelessConf !== undefined && wirelessConf.wireless_enabled !== undefined && wirelessConf.wireless_enabled.value !== undefined && !wirelessConf.wireless_enabled.value) {
        wirelessDisabled = true;
    }
    return wirelessDisabled
}

function hotspotFallbackCondition() {
    var hotspotFallbackConf = getWirelessConfiguration();
    var startHotspotFallback = false;
    if (hotspotFallbackConf !== undefined && hotspotFallbackConf.hotspot_fallback !== undefined && hotspotFallbackConf.hotspot_fallback.value !== undefined && hotspotFallbackConf.hotspot_fallback.value) {
        startHotspotFallback = true;
    }
    if (!startHotspotFallback && !hasWirelessConnectionBeenEstablishedOnce()) {
        startHotspotFallback = true;
    }
    return startHotspotFallback
}

function saveWirelessConnectionEstablished() {
    try {
        fs.ensureFileSync(WIRELESS_ESTABLISHED_FLAG)
    } catch (e) {
        loggerDebug('Could not save Wireless Connection Established: ' + e);
    }
}

function hasWirelessConnectionBeenEstablishedOnce() {
    var wirelessEstablished = false;
    try {
        if (fs.existsSync(WIRELESS_ESTABLISHED_FLAG)) {
            wirelessEstablished = true;
        }
    } catch(err) {}
    return wirelessEstablished
}

function getWirelessWPADriverString() {
    try {
        var volumioHW = execSync("cat /etc/os-release | grep ^VOLUMIO_HARDWARE | tr -d 'VOLUMIO_HARDWARE=\"'", { uid: 1000, gid: 1000, encoding: 'utf8'}).replace('\n','');
    } catch(e) {
        var volumioHW = 'none';
    }
    var fullDriver = 'nl80211,wext';
    var onlyWextDriver = 'wext';
    if (volumioHW === 'nanopineo2') {
        return onlyWextDriver
    } else {
        return fullDriver
    }
}

function detectAndApplyRegdomain(callback) {
    if (isWirelessDisabled()) {
        return callback();
    }
    var appropriateRegDom = '00';
    try {
        var currentRegDomain = execSync("/usr/bin/sudo /sbin/ifconfig wlan0 up && /usr/bin/sudo /sbin/iw reg get | grep country | cut -f1 -d':'", { uid: 1000, gid: 1000, encoding: 'utf8'}).replace(/country /g, '').replace('\n','');
        var countryCodesInScan = execSync("/usr/bin/sudo /sbin/ifconfig wlan0 up && /usr/bin/sudo /sbin/iw wlan0 scan | grep Country: | cut -f 2", { uid: 1000, gid: 1000, encoding: 'utf8'}).replace(/Country: /g, '').split('\n');
        var appropriateRegDomain = determineMostAppropriateRegdomain(countryCodesInScan);
        loggerDebug('CURRENT REG DOMAIN: ' + currentRegDomain)
        loggerDebug('APPROPRIATE REG DOMAIN: ' + appropriateRegDomain)
        if (isValidRegDomain(appropriateRegDomain) && appropriateRegDomain !== currentRegDomain) {
            applyNewRegDomain(appropriateRegDomain);
        }
    } catch(e) {
        loggerInfo('Failed to determine most appropriate reg domain: ' + e);
    }
    callback();
}

function applyNewRegDomain(newRegDom) {
    loggerInfo('SETTING APPROPRIATE REG DOMAIN: ' + newRegDom);

    try {
        execSync("/usr/bin/sudo /sbin/ifconfig wlan0 up && /usr/bin/sudo /sbin/iw reg set " + newRegDom, { uid: 1000, gid: 1000, encoding: 'utf8'});
        //execSync("/usr/bin/sudo /bin/echo 'REGDOMAIN=" + newRegDom + "' > /etc/default/crda", { uid: 1000, gid: 1000, encoding: 'utf8'});
        fs.writeFileSync(CRDA_CONFIG, "REGDOMAIN=" + newRegDom);
        loggerInfo('SUCCESSFULLY SET NEW REGDOMAIN: ' + newRegDom)
    } catch(e) {
        loggerInfo('Failed to set new reg domain: ' + e);
    }

}

function isValidRegDomain(regDomain) {
    if (regDomain && regDomain.length === 2) {
        return true;
    } else {
        return false;
    }
}

function determineMostAppropriateRegdomain(arr) {
    let compare = "";
    let mostFreq = "";
    if (!arr.length) {
        arr = ['00'];
    }
    arr.reduce((acc, val) => {
        if(val in acc){
            acc[val]++;
        }else{
            acc[val] = 1;
        }
        if(acc[val] > compare){
            compare = acc[val];
            mostFreq = val;
        }
        return acc;
    }, {})
    return mostFreq;
}

function checkConcurrentModeSupport() {
    try {
        const output = execSync('iw list', { encoding: 'utf8' });
        const comboRegex = /valid interface combinations([\s\S]*?)(?=\n\n)/i;
        const comboBlock = output.match(comboRegex);

        if (!comboBlock || comboBlock.length < 2) {
            loggerDebug('WIRELESS: No interface combination block found.');
            return false;
        }

        const comboText = comboBlock[1];

        const hasAP = comboText.includes('AP');
        const hasSTA = comboText.includes('station') || comboText.includes('STA');

        if (hasAP && hasSTA) {
            loggerInfo('WIRELESS: Concurrent AP+STA mode supported.');
            return true;
        } else {
            loggerInfo('WIRELESS: Concurrent AP+STA mode NOT supported.');
            return false;
        }
    } catch (err) {
        loggerInfo('WIRELESS: Failed to determine interface mode support: ' + err);
        return false;
    }
}

function startWiredNetworkingMonitor() {
    try {
        fs.accessSync(ETH_STATUS_FILE);
    } catch (error) {
        fs.writeFileSync(ETH_STATUS_FILE, 'disconnected', 'utf8');
    }
    checkWiredNetworkStatus(true);
    fs.watch(ETH_STATUS_FILE, () => {
        checkWiredNetworkStatus();
    });
}

function checkWiredNetworkStatus(isFirstStart) {
    try {
        // Validate actual hardware state
        var actualState = 'disconnected';
        try {
            var carrier = fs.readFileSync('/sys/class/net/eth0/carrier', 'utf8').trim();
            if (carrier === '1') {
                actualState = 'connected';
            }
        } catch (e) {
            actualState = 'disconnected';
        }
        
        // Check if state changed BEFORE writing to file
        // Writing to file triggers fs.watch() callback - only write when state actually changes
        if (actualState !== currentEthStatus) {
            // Update file ONLY when state changes (prevents infinite loop)
            try {
                fs.writeFileSync(ETH_STATUS_FILE, actualState, 'utf8');
            } catch (e) {
                loggerDebug('Could not update eth0status: ' + e);
            }
            
            // Start timing transition for diagnostics
            transitionStartTime = Date.now();
            
            // Enhanced transition logging
            loggerInfo("=== SNM TRANSITION ===");
            loggerInfo("Previous ethernet state: " + currentEthStatus);
            loggerInfo("New ethernet state: " + actualState);
            loggerInfo("Single Network Mode: " + (singleNetworkMode ? "enabled" : "disabled"));
            loggerInfo("First start: " + (isFirstStart ? "yes" : "no"));
            
            currentEthStatus = actualState;
            
            if (actualState === 'connected') {
                // Ethernet connected
                isWiredNetworkActive = true;
                loggerInfo("Action: Switch to ethernet (WiFi scan mode)");
                loggerInfo("=== END TRANSITION ===");
                
                if (!isFirstStart && singleNetworkMode) {
                    loggerInfo('SNM: Ethernet connected, switching to ethernet (WiFi scan mode)');
                    
                    // FIX v4.0-rc3: Release wlan0 DHCP lease before transition to prevent stale lease rebind
                    // When reconnecting later, dhcpcd will request fresh lease instead of trying to rebind
                    // expired lease which can fail or timeout on some routers
                    try {
                        loggerDebug('SNM: Releasing wlan0 DHCP lease before ethernet transition');
                        execSync(SUDO + ' ' + DHCPCD + ' -k ' + wlan, { 
                            encoding: 'utf8', 
                            timeout: EXEC_TIMEOUT_SHORT 
                        });
                        loggerDebug('SNM: wlan0 DHCP lease released successfully');
                    } catch (e) {
                        // Non-fatal - may not have active lease
                        loggerDebug('SNM: DHCP release skipped (no active lease): ' + e.message);
                    }
                    
                    // Use setImmediate to break out of fs.watch() callback context
                    // Direct call causes deadlock in thus.exec()
                    loggerDebug('SNM: Scheduling wireless flow restart via setImmediate()');
                    setImmediate(function() {
                        loggerDebug('SNM: setImmediate() callback FIRED - calling initializeWirelessFlow()');
                        try {
                            initializeWirelessFlow();
                        } catch (e) {
                            loggerInfo('SNM: ERROR in initializeWirelessFlow(): ' + e);
                            loggerInfo('SNM: Stack: ' + e.stack);
                        }
                    });
                    loggerDebug('SNM: setImmediate() scheduled, continuing...');
                }
                
            } else {
                // Ethernet disconnected
                isWiredNetworkActive = false;
                loggerInfo("Action: Reconnect WiFi");
                loggerInfo("=== END TRANSITION ===");
                
                if (!isFirstStart && singleNetworkMode) {
                    // Check if WiFi is already connected
                    try {
                        var wifiSSID = execSync(iwgetid, { uid: 1000, gid: 1000, encoding: 'utf8' }).replace('\n','');
                        if (wifiSSID && wifiSSID.length > 0) {
                            loggerInfo('SNM: WiFi already connected to: ' + wifiSSID);
                            return;
                        }
                    } catch (e) {
                        loggerDebug('SNM: Could not check WiFi status: ' + e);
                    }
                    
                    // WiFi not connected, trigger reconnection
                    loggerInfo('SNM: Ethernet disconnected, reconnecting WiFi');
                    // Use setImmediate to break out of fs.watch() callback context
                    loggerDebug('SNM: Scheduling WiFi reconnect via setImmediate()');
                    setImmediate(function() {
                        loggerDebug('SNM: setImmediate() callback FIRED - calling reconnectWiFiAfterEthernet()');
                        try {
                            reconnectWiFiAfterEthernet();
                        } catch (e) {
                            loggerInfo('SNM: ERROR in reconnectWiFiAfterEthernet(): ' + e);
                            loggerInfo('SNM: Stack: ' + e.stack);
                        }
                    });
                    loggerDebug('SNM: setImmediate() scheduled, continuing...');
                }
            }
        }
        
        loggerDebug('checkWiredNetworkStatus: Function complete');
    } catch (e) {
        loggerInfo('Error in checkWiredNetworkStatus: ' + e);
        loggerInfo('Stack: ' + e.stack);
    }
}

function retrieveEnvParameters() {
    // Facility function to read env parameters, without the need for external modules
    try {
        var envParameters = fs.readFileSync(VOLUMIO_ENV, { encoding: 'utf8'});
        if (envParameters.includes('SINGLE_NETWORK_MODE=true')) {
            singleNetworkMode = true;
            loggerInfo('Single Network Mode enabled, only one network device can be active at a time between ethernet and wireless');
        }
    } catch(e) {
        loggerDebug('Could not read /volumio/.env file: ' + e);
    }
}

function notifyWirelessReady() {
    exec('systemd-notify --ready', { stdio: 'inherit', shell: '/bin/bash', uid: process.getgid(), gid: process.geteuid(), encoding: 'utf8'}, function(error) {
        if (error) {
            loggerInfo('Could not notify systemd about wireless ready: ' + error);
        } else {
            loggerInfo('Notified systemd about wireless ready');
        }
    });
}

function checkInterfaceReleased() {
    try {
        const output = execSync('ip link show wlan0').toString();
        return output.includes('state DOWN') || output.includes('NO-CARRIER');
    } catch (e) {
        return false;
    }
}

function isConfiguredSSIDVisible() {
    try {
        const config = getWirelessConfiguration();
        const ssid = config.wlanssid?.value;
        const scan = execSync('/usr/bin/sudo /sbin/iw wlan0 scan | grep SSID:', { encoding: 'utf8' });
        return ssid && scan.includes(ssid);
    } catch (e) {
        return false;
    }
}

function waitForInterfaceReleaseAndStartAP() {
    // Prevent duplicate calls
    if (apStartInProgress) {
        loggerDebug("AP start already in progress, ignoring duplicate call");
        return;
    }

    apStartInProgress = true;

    const MAX_WAIT = 8000;
    const INTERVAL = 1000;
    let waited = 0;

    const wait = () => {
        if (checkInterfaceReleased()) {
            loggerDebug("Interface wlan0 released. Proceeding with startAP...");
            startAP(function () {
                if (wpaerr > 0) {
                    retryCount++;
                    loggerInfo(`startAP failed. Retry ${retryCount} of ${maxRetries}`);
                    if (retryCount < maxRetries) {
                        apStartInProgress = false; // Reset before retry
                        setTimeout(waitForInterfaceReleaseAndStartAP, 2000);
                    } else {
                        loggerInfo("startAP reached max retries. Attempting fallback.");
                        apStartInProgress = false;
                        startHotspotFallbackSafe();
                    }
                } else {
                    afterAPStart();
                }
            });
        } else if (waited >= MAX_WAIT) {
            loggerDebug("Timeout waiting for wlan0 release. Proceeding with startAP anyway...");
            startAP(function () {
                if (wpaerr > 0) {
                    retryCount++;
                    loggerInfo(`startAP failed. Retry ${retryCount} of ${maxRetries}`);
                    if (retryCount < maxRetries) {
                        apStartInProgress = false; // Reset before retry
                        setTimeout(waitForInterfaceReleaseAndStartAP, 2000);
                    } else {
                        loggerInfo("startAP reached max retries. Attempting fallback.");
                        apStartInProgress = false;
                        startHotspotFallbackSafe();
                    }
                } else {
                    afterAPStart();
                }
            });
        } else {
            waited += INTERVAL;
            setTimeout(wait, INTERVAL);
        }
    };
    wait();
}

function afterAPStart() {
    loggerInfo("Start ap");
    actualTime = 0; // Reset timer

    // Make absolutely sure no old timer exists
    clearConnectionTimer();

    lesstimer = setInterval(()=> {
        actualTime += pollingTime;
        if (wpaerr > 0) {
            actualTime = totalSecondsForConnection + 1;
        }

        if (actualTime > totalSecondsForConnection) {
            loggerInfo("Overtime, connection failed. Evaluating hotspot condition.");

            // Clear timer immediately
            clearConnectionTimer();
            apStartInProgress = false; // Reset flag
            wirelessFlowInProgress = false; // Reset flow flag

            const fallbackEnabled = hotspotFallbackCondition();
            const ssidMissing = !isConfiguredSSIDVisible();
            const firstBoot = !hasWirelessConnectionBeenEstablishedOnce();

            if (!isWirelessDisabled() && (fallbackEnabled || ssidMissing || firstBoot)) {
                if (checkConcurrentModeSupport()) {
                    loggerInfo('Concurrent AP+STA supported. Starting hotspot without stopping STA.');
                    startHotspot(function (err) {
                        if (err) {
                            loggerInfo('Could not start Hotspot Fallback: ' + err);
                        } else {
                            updateNetworkState("hotspot");
                        }
                        notifyWirelessReady();
                    });
                } else {
                    loggerInfo('No concurrent mode. Stopping STA and starting hotspot.');
                    apstopped = 1;
                    stopAP(function () {
                        setTimeout(()=> {
                            startHotspot(function (err) {
                                if (err) {
                                    loggerInfo('Could not start Hotspot Fallback: ' + err);
                                } else {
                                    updateNetworkState("hotspot");
                                }
                                notifyWirelessReady();
                            });
                        }, settleTime);
                    });
                }
            } else {
                apstopped = 0;
                updateNetworkState("ap");
                notifyWirelessReady();
            }

            return; // Exit callback
        } else {
            var SSID = undefined;
            loggerInfo("trying...");
            try {
                SSID = execSync("/usr/bin/sudo /sbin/iwgetid -r", { uid: 1000, gid: 1000, encoding: 'utf8' }).replace('\n','');
                loggerInfo('Connected to: ----' + SSID + '----');
            } catch (e) {}

            if (SSID !== undefined) {
                ifconfig.status(wlan, function (err, ifstatus) {
                    loggerInfo("... joined AP, wlan0 IPv4 is " + ifstatus.ipv4_address + ", ipV6 is " + ifstatus.ipv6_address);
                    if (((ifstatus.ipv4_address != undefined && ifstatus.ipv4_address.length > "0.0.0.0".length) ||
                        (ifstatus.ipv6_address != undefined && ifstatus.ipv6_address.length > "::".length))) {
                        if (apstopped == 0) {
                            loggerInfo("It's done! AP");
                            retryCount = 0;

                            // Clear timer
                            clearConnectionTimer();
                            apStartInProgress = false; // Reset flag
                            wirelessFlowInProgress = false; // Reset flow flag

                            updateNetworkState("ap");
                            restartAvahi();
                            saveWirelessConnectionEstablished();
                            notifyWirelessReady();
                        }
                    }
                });
            }
        }
    }, pollingTime * 1000);
}
