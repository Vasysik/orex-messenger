{{flutter_js}}
{{flutter_build_config}}

// Retire Flutter's legacy generated service worker if an older Orex release
// registered one. Current Flutter web builds do not generate one by default.
if ('serviceWorker' in navigator) {
  navigator.serviceWorker.getRegistrations().then(function (registrations) {
    registrations.forEach(function (registration) {
      var worker = registration.active || registration.waiting || registration.installing;
      if (worker && worker.scriptURL.indexOf('/flutter_service_worker.js') !== -1) {
        registration.unregister();
      }
    });
  }).catch(function () {});
}

// Keep bootstrap deliberately simple. Cache freshness is handled by nginx,
// rather than rewriting Flutter entrypoint/asset URLs in JavaScript.
_flutter.loader.load({
  onEntrypointLoaded: async function (engineInitializer) {
    const appRunner = await engineInitializer.initializeEngine();
    await appRunner.runApp();

    // Let Flutter paint before removing the HTML loading surface.
    requestAnimationFrame(function () {
      requestAnimationFrame(function () {
        const bootstrap = document.getElementById('orex-bootstrap');
        if (!bootstrap) return;
        bootstrap.classList.add('orex-bootstrap-hide');
        window.setTimeout(function () { bootstrap.remove(); }, 180);
      });
    });
  },
});
