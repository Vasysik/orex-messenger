(() => {
  'use strict';

  const FEED_URL = '/updates/stable/latest.json';
  const RELEASE_PREFIX = '/updates/stable/';

  const status = document.getElementById('release-status');

  const targets = {
    'windows-x64': {
      link: document.getElementById('download-windows'),
      size: document.getElementById('size-windows'),
      extension: '.exe',
    },
    'android-arm64-v8a': {
      link: document.getElementById('download-android-arm64'),
      size: document.getElementById('size-android-arm64'),
      extension: '.apk',
    },
    'android-armeabi-v7a': {
      link: document.getElementById('download-android-armv7'),
      size: document.getElementById('size-android-armv7'),
      extension: '.apk',
    },
  };

  function formatBytes(value) {
    if (!Number.isFinite(value) || value <= 0) return null;
    const megabytes = value / (1024 * 1024);
    return `${megabytes.toLocaleString('ru-RU', {
      maximumFractionDigits: 1,
      minimumFractionDigits: megabytes < 10 ? 1 : 0,
    })} МБ`;
  }

  function safeArtifact(artifact, extension) {
    if (!artifact || typeof artifact.url !== 'string') return null;
    if (!artifact.url.startsWith(RELEASE_PREFIX)) return null;
    if (!artifact.url.toLowerCase().endsWith(extension)) return null;
    return artifact;
  }

  function enableTarget(target, artifact) {
    target.link.href = artifact.url;
    target.link.classList.remove('is-disabled');
    target.link.removeAttribute('aria-disabled');

    const formattedSize = formatBytes(Number(artifact.size_bytes));
    if (formattedSize) {
      target.size.textContent = formattedSize;
    }
  }

  async function loadRelease() {
    try {
      const response = await fetch(FEED_URL, {
        cache: 'no-store',
        credentials: 'same-origin',
      });
      if (!response.ok) {
        throw new Error(`Update feed returned ${response.status}`);
      }

      const payload = await response.json();
      const version = typeof payload.version === 'string' ? payload.version : null;
      const build = Number(payload.build);
      if (!version || !Number.isInteger(build) || build <= 0) {
        throw new Error('Update feed contains an invalid release identifier');
      }

      const artifacts = payload.artifacts || {};
      let availableCount = 0;
      for (const [key, target] of Object.entries(targets)) {
        const artifact = safeArtifact(artifacts[key], target.extension);
        if (!artifact) continue;
        enableTarget(target, artifact);
        availableCount += 1;
      }

      if (availableCount === 0) {
        throw new Error('Update feed contains no downloadable artifacts');
      }

      status.textContent = `Стабильная версия ${version} · сборка ${build}`;
    } catch (error) {
      console.error('[orex-download] Failed to load release feed', error);
      status.textContent = 'Не удалось получить актуальную сборку. Обновите страницу позже.';
      status.classList.add('is-error');
    }
  }

  loadRelease();
})();
