#ifndef RUNNER_OREX_PLUGIN_REGISTRANT_H_
#define RUNNER_OREX_PLUGIN_REGISTRANT_H_

#include <flutter_windows.h>

// Registers Orex Windows plugins except multiview_desktop itself. The
// multiview_desktop runner owns registration of its plugin on the shared
// engine. Keep this list in sync with generated_plugin_registrant.cc when
// adding/removing Windows plugins.
void RegisterOrexPlugins(FlutterDesktopEngineRef engine);

#endif  // RUNNER_OREX_PLUGIN_REGISTRANT_H_
