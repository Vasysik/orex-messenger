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

  const videoContainsTrack = (video, trackId) => {
    const stream = video && video.srcObject;
    return !!stream &&
      typeof stream.getVideoTracks === 'function' &&
      stream.getVideoTracks().some((track) => track.id === trackId);
  };

  const preferredVideoForTrack = (trackId, preferredElementId) => {
    if (!preferredElementId) return null;
    const preferred = document.getElementById(preferredElementId);
    return preferred instanceof HTMLVideoElement &&
      videoContainsTrack(preferred, trackId)
      ? preferred
      : null;
  };

  const findReadyVideoForTrack = (trackId, preferredElementId) => {
    const preferred = preferredVideoForTrack(trackId, preferredElementId);
    if (preferred && preferred.readyState !== HTMLMediaElement.HAVE_NOTHING) {
      return preferred;
    }

    for (const video of document.querySelectorAll('video')) {
      if (video === preferred) continue;
      if (video.readyState === HTMLMediaElement.HAVE_NOTHING) continue;
      if (videoContainsTrack(video, trackId)) return video;
    }
    return preferred;
  };

  const installLeaveHandler = (video) => {
    video.addEventListener('leavepictureinpicture', (event) => {
      // Chrome may switch an already-open PiP from the visible call-tile video
      // to Orex's stable hidden renderer once that renderer has metadata. Ignore
      // the old element's leave event during that migration.
      if (pipVideo !== event.currentTarget) return;
      pipVideo = null;
      if (closedCallback) closedCallback();
    }, { once: true });
  };

  const promoteStableVideo = async (trackId, preferred, current) => {
    if (!preferred || preferred === current) return;
    if (pipVideo !== current || document.pictureInPictureElement !== current) {
      return;
    }
    if (!videoContainsTrack(preferred, trackId) ||
        preferred.readyState === HTMLMediaElement.HAVE_NOTHING ||
        typeof preferred.requestPictureInPicture !== 'function') {
      return;
    }

    const previous = pipVideo;
    pipVideo = preferred;
    try {
      // In Chrome, once a document already owns a PiP window, switching the
      // element does not require a second user gesture. This lets the initial
      // click use an already-playing tile while the dedicated renderer warms.
      await preferred.requestPictureInPicture();
      installLeaveHandler(preferred);
    } catch (_) {
      pipVideo = document.pictureInPictureElement === previous ? previous : null;
    }
  };

  window.orexSetPictureInPictureClosedCallback = (callback) => {
    closedCallback = typeof callback === 'function' ? callback : null;
  };

  window.orexOpenPictureInPicture = async (trackId, preferredElementId) => {
    if (!document.pictureInPictureEnabled) return false;
    const preferred = preferredVideoForTrack(trackId, preferredElementId);
    const video = findReadyVideoForTrack(trackId, preferredElementId);
    if (!video || typeof video.requestPictureInPicture !== 'function') {
      return false;
    }

    if (document.pictureInPictureElement === video) return true;
    if (document.pictureInPictureElement) {
      await document.exitPictureInPicture();
    }

    await video.requestPictureInPicture();
    pipVideo = video;
    installLeaveHandler(video);

    if (preferred && preferred !== video) {
      const promote = () => {
        void promoteStableVideo(trackId, preferred, video);
      };
      if (preferred.readyState !== HTMLMediaElement.HAVE_NOTHING) {
        queueMicrotask(promote);
      } else {
        preferred.addEventListener('loadedmetadata', promote, { once: true });
      }
    }
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
