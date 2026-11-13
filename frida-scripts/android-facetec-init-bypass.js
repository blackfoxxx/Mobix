/**************************************************************************************************
 *
 * FaceTec SDK production-mode init bypass.
 *
 * FaceTecSDK.initializeInProductionMode() runs FaceTec's own device-integrity
 * checks (root/emulator/tamper/instrumentation) independently of whatever the
 * host app does. The rest of this lab's chain only hooks Java-layer signals
 * (su binaries, Build fields, TracerPid, Frida paths, ...); a commercial
 * anti-spoofing vendor's own check plausibly runs in native code this chain
 * never touches, and a rooted/virtualized/instrumented device is exactly what
 * it exists to refuse. Confirmed on mobi.foo.zaincash: the key data reaching
 * initializeInProductionMode is valid (correct expiry, correct appId, key
 * bytes match live GetKeys()) - the failure is the init verdict itself, not
 * bad key material.
 *
 * Rather than reverse-engineer that native check, this hooks the app's own
 * result callback and forces the success branch regardless of the real
 * verdict. Targets the app-side wrapper (f.C2630b in mobi.foo.zaincash,
 * implements FaceTecSDK.InitializeCallback), not FaceTec's SDK class itself -
 * this only changes how the app reacts to the result, not FaceTec's internal
 * state, and stays safely no-op (wrapped, silent) on any app whose obfuscated
 * class name differs.
 *
 * Honest limits: this is app-specific (the obfuscated wrapper class name
 * will differ per app/build) and confirms init *completes*, not that later
 * FaceTecSession calls behave identically to a real pass. Treat a
 * successfully-forced init as a resilience finding in its own right - the
 * SDK's device-integrity verdict was overridable from the app layer alone -
 * not as proof the underlying liveness/match logic was also defeated.
 *
 *************************************************************************************************/

(function () {
    const LOG = (typeof DEBUG_MODE !== 'undefined') && DEBUG_MODE;
    const say = (m) => { if (LOG) console.log('[facetec-init-bypass] ' + m); else console.log('[facetec-init-bypass] ' + m); };

    // App-specific obfuscated class name (verified against mobi.foo.zaincash's
    // decompiled sources: implements com.facetec.sdk.FaceTecSDK$InitializeCallback,
    // logs "Initialization was not completed successfully..." on failure).
    // Real runtime name is f.b - jadx's source file is named C2630b.java only
    // because the true name collides case-insensitively with another class
    // ("JADX INFO: renamed from: f.b, reason: case insensitive filesystem").
    // Try both in case a different build/obfuscation pass changes this.
    const CANDIDATE_CLASSES = ['f.b', 'f.C2630b'];

    // Two reasons Java.use() can fail to find a real, present class:
    // 1. The callback class is only loaded once the app navigates into the
    //    liveness/camera screen - not loaded yet at attach time.
    // 2. This app is MultiDex (classes.dex through classes4.dex). Java.use()
    //    only searches the default classloader; a class from a secondary dex
    //    can live under a different one entirely, and will never resolve no
    //    matter how long you poll unless you point Java.classFactory.loader
    //    at the classloader that actually has it.
    // Handle both: poll for the class to load, and on each attempt search
    // every live classloader rather than trusting the default one.
    // Poll until the class loads, then stop - do NOT keep re-hooking
    // indefinitely. An earlier version of this script polled forever on a
    // 1-second timer to work around hooks silently disappearing; the real
    // cause of that was launching frida with -q, which detaches (and
    // reverts all hooks) once a script's initial synchronous work settles.
    // Fixed at the launcher level (no -q). Once that's fixed, indefinite
    // enumerateClassLoaders() polling is just unnecessary load during the
    // process's most fragile moment (spawn-time, alongside the rest of the
    // chain's own hooking) - this app already crashes occasionally under
    // the full chain even without extra polling on top of it. Back off
    // instead: check often at first (the class loads within a few seconds
    // of the liveness screen opening), then increasingly rarely, and give
    // up after a generous ceiling rather than polling forever.
    const MAX_ATTEMPTS = 60; // ~10 minutes total with the backoff below
    let attempt = 0;
    let hooked = false;

    function findLoaderFor(className) {
        let found = null;
        Java.enumerateClassLoadersSync().forEach(function (loader) {
            if (found) return;
            try {
                loader.findClass(className);
                found = loader;
            } catch (e) {
                // This loader doesn't have it - expected for most of them.
            }
        });
        return found;
    }

    function tryHook() {
        if (hooked) return;
        Java.perform(function () {
            for (const cls of CANDIDATE_CLASSES) {
                if (hooked) break;
                const loader = findLoaderFor(cls);
                if (!loader) continue; // not loaded by any classloader yet
                try {
                    const prevLoader = Java.classFactory.loader;
                    Java.classFactory.loader = loader;
                    const Callback = Java.use(cls);
                    Callback.onCompletion.overload('boolean').implementation = function (z5) {
                        say('onCompletion invoked, real result: ' + z5 + (z5 ? '' : ' - forcing true'));
                        this.onCompletion(true);
                    };
                    Java.classFactory.loader = prevLoader;
                    say('hooked ' + cls + '.onCompletion');
                    hooked = true;
                } catch (e) {
                    say('found ' + cls + ' but hook install failed: ' + e);
                }
            }
        });
        attempt++;
        if (!hooked && attempt < MAX_ATTEMPTS) {
            const delay = Math.min(1000 * Math.pow(1.15, attempt), 30000);
            setTimeout(tryHook, delay);
        } else if (!hooked) {
            say('gave up waiting for ' + CANDIDATE_CLASSES.join(',') + ' to load');
        }
    }

    tryHook();
})();
