{{flutter_js}}
{{flutter_build_config}}

// Install the Web PiP bridge from an external same-origin script so production
// CSP never needs 'unsafe-inline'. Keeping the bridge in flutter_bootstrap.js
// also makes it available before Flutter/Dart starts and survives a brief mixed
// index.html/main.dart.js deployment as long as the bootstrap itself is current.
(function ensureOrexPictureInPictureBridge() {
  if (
    typeof window.orexOpenPictureInPicture === 'function' &&
    typeof window.orexClosePictureInPicture === 'function' &&
    typeof window.orexSetPictureInPictureClosedCallback === 'function'
  ) {
    return;
  }

  let closedCallback = null;
  let pipVideo = null;

  const findVideoForTrack = (trackId) => {
    for (const video of document.querySelectorAll('video')) {
      const stream = video.srcObject;
      if (!stream || typeof stream.getVideoTracks !== 'function') continue;
      if (stream.getVideoTracks().some((track) => track.id === trackId)) {
        return video;
      }
    }
    return null;
  };

  window.orexSetPictureInPictureClosedCallback = (callback) => {
    closedCallback = typeof callback === 'function' ? callback : null;
  };

  window.orexOpenPictureInPicture = async (trackId) => {
    if (!document.pictureInPictureEnabled) return false;
    const video = findVideoForTrack(trackId);
    if (!video || typeof video.requestPictureInPicture !== 'function') {
      return false;
    }

    if (document.pictureInPictureElement === video) return true;
    if (document.pictureInPictureElement) {
      await document.exitPictureInPicture();
    }

    await video.requestPictureInPicture();
    pipVideo = video;
    video.addEventListener('leavepictureinpicture', () => {
      if (pipVideo === video) pipVideo = null;
      if (closedCallback) closedCallback();
    }, { once: true });
    return true;
  };

  window.orexClosePictureInPicture = async () => {
    if (document.pictureInPictureElement) {
      await document.exitPictureInPicture();
    }
    pipVideo = null;
  };
})();

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
