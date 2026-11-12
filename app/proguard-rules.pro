# SPDX-FileCopyrightText: 2026 amurcanov
# SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0

# Release-only: drop verbose/debug logcat calls. R8 keeps them otherwise, because
# Log.d/Log.v have unknown side effects, and their string literals stay in the dex
# too. Info/warn/error are deliberately kept - they are the only diagnostics left
# in a release build. Debug builds are not minified, so they keep every call.
#
# This affects the logcat channel only. The in-app journal shown in LogsTab is a
# user-facing feature (it is what users attach to support reports) and has no
# Log.* calls on its path, so it keeps working in release.
-assumenosideeffects class android.util.Log {
    public static *** d(...);
    public static *** v(...);
}
