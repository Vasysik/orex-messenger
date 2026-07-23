package com.cloudwebrtc.webrtc;

import org.webrtc.SurfaceTextureHelper;
import org.webrtc.CapturerObserver;
import org.webrtc.ThreadUtils;
import org.webrtc.VideoCapturer;
import org.webrtc.VideoFrame;
import org.webrtc.VideoSink;

import android.annotation.TargetApi;
import android.content.Context;
import android.content.Intent;
import android.media.projection.MediaProjection;
import android.view.Surface;
import android.view.WindowManager;
import android.app.Activity;
import android.hardware.display.DisplayManager;
import android.util.DisplayMetrics;
import android.hardware.display.VirtualDisplay;
import android.media.projection.MediaProjectionManager;
import android.view.Display;

import java.util.HashMap;
import java.util.Map;
import java.util.concurrent.atomic.AtomicBoolean;

/**
 * Orex source overlay for flutter_webrtc 1.5.2.
 *
 * The upstream capturer registers the callback supplied by GetUserMediaImpl,
 * but that callback intentionally does nothing. Android calls onStop when a
 * user taps the system status-chip Stop action or locks the device; forwarding
 * that transition to Flutter is required to unpublish the screen track and
 * release the MediaProjection foreground service.
 */
@TargetApi(21)
public class OrientationAwareScreenCapturer implements VideoCapturer, VideoSink {
    private static final int DISPLAY_FLAGS =
            DisplayManager.VIRTUAL_DISPLAY_FLAG_PUBLIC | DisplayManager.VIRTUAL_DISPLAY_FLAG_PRESENTATION;
    private static final int VIRTUAL_DISPLAY_DPI = 400;
    private final Intent mediaProjectionPermissionResultData;
    private final MediaProjection.Callback mediaProjectionCallback;
    private int width;
    private int height;
    private int oldWidth;
    private int oldHeight;
    private VirtualDisplay virtualDisplay;
    private Surface virtualDisplaySurface;
    private SurfaceTextureHelper surfaceTextureHelper;
    private CapturerObserver capturerObserver;
    private long numCapturedFrames = 0;
    private MediaProjection mediaProjection;
    private volatile boolean isDisposed = false;
    private MediaProjectionManager mediaProjectionManager;
    private WindowManager windowManager;
    private boolean isPortrait;
    // Do not use the capturer monitor for this gate. stopCapture() has to wait
    // for SurfaceTextureHelper's handler, while Android invokes onStop on that
    // same handler; holding the monitor there would deadlock the callback.
    private final AtomicBoolean captureResourcesReleased = new AtomicBoolean(false);

    public OrientationAwareScreenCapturer(
            Intent mediaProjectionPermissionResultData,
            MediaProjection.Callback upstreamMediaProjectionCallback) {
        this.mediaProjectionPermissionResultData = mediaProjectionPermissionResultData;
        this.mediaProjectionCallback = new MediaProjection.Callback() {
            @Override
            public void onStop() {
                if (!releaseProjectionAfterSystemStop()) {
                    return;
                }
                try {
                    if (upstreamMediaProjectionCallback != null) {
                        upstreamMediaProjectionCallback.onStop();
                    }
                } finally {
                    emitScreenCaptureStopped();
                }
            }
        };
    }

    public void onFrame(VideoFrame frame) {
        checkNotDisposed();
        this.isPortrait = isDeviceOrientationPortrait();
        final int max = Math.max(this.height, this.width);
        final int min = Math.min(this.height, this.width);
        if (this.isPortrait) {
            changeCaptureFormat(min, max, 15);
        } else {
            changeCaptureFormat(max, min, 15);
        }
        capturerObserver.onFrameCaptured(frame);
    }

    private boolean isDeviceOrientationPortrait() {
        final Display display = windowManager.getDefaultDisplay();
        final DisplayMetrics metrics = new DisplayMetrics();
        display.getRealMetrics(metrics);
        return metrics.heightPixels > metrics.widthPixels;
    }

    private void checkNotDisposed() {
        if (isDisposed) {
            throw new RuntimeException("capturer is disposed.");
        }
    }

    public synchronized void initialize(
            final SurfaceTextureHelper surfaceTextureHelper,
            final Context applicationContext,
            final CapturerObserver capturerObserver) {
        checkNotDisposed();
        if (capturerObserver == null) {
            throw new RuntimeException("capturerObserver not set.");
        }
        this.capturerObserver = capturerObserver;
        if (surfaceTextureHelper == null) {
            throw new RuntimeException("surfaceTextureHelper not set.");
        }
        this.surfaceTextureHelper = surfaceTextureHelper;
        this.windowManager = (WindowManager) applicationContext.getSystemService(Context.WINDOW_SERVICE);
        this.mediaProjectionManager = (MediaProjectionManager) applicationContext.getSystemService(
                Context.MEDIA_PROJECTION_SERVICE);
    }

    @Override
    public synchronized void startCapture(
            final int width,
            final int height,
            final int ignoredFramerate) {
        captureResourcesReleased.set(false);
        this.isPortrait = isDeviceOrientationPortrait();
        if (this.isPortrait) {
            this.width = width;
            this.height = height;
        } else {
            this.height = width;
            this.width = height;
        }
        this.oldWidth = this.width;
        this.oldHeight = this.height;

        mediaProjection = mediaProjectionManager.getMediaProjection(
                Activity.RESULT_OK,
                mediaProjectionPermissionResultData);
        mediaProjection.registerCallback(mediaProjectionCallback, surfaceTextureHelper.getHandler());

        createVirtualDisplay();
        capturerObserver.onCapturerStarted(true);
        surfaceTextureHelper.startListening(this);
    }

    @Override
    public void stopCapture() {
        checkNotDisposed();
        // Claim cleanup before hopping to SurfaceTextureHelper's handler. A
        // concurrent system revoke then becomes a no-op rather than releasing
        // the capturer twice or emitting a false revoke event.
        if (!captureResourcesReleased.compareAndSet(false, true)) {
            return;
        }
        ThreadUtils.invokeAtFrontUninterruptibly(surfaceTextureHelper.getHandler(), new Runnable() {
            @Override
            public void run() {
                releaseProjectionResources(true);
            }
        });
    }

    @Override
    public synchronized void dispose() {
        isDisposed = true;
    }

    @Override
    public synchronized void changeCaptureFormat(
            final int width,
            final int height,
            final int ignoredFramerate) {
        checkNotDisposed();
        if (this.oldWidth != width || this.oldHeight != height) {
            this.width = width;
            this.height = height;
            this.oldWidth = width;
            this.oldHeight = height;

            ThreadUtils.invokeAtFrontUninterruptibly(surfaceTextureHelper.getHandler(), new Runnable() {
                @Override
                public void run() {
                    if (surfaceTextureHelper == null || mediaProjection == null) {
                        return;
                    }
                    if (virtualDisplay != null) {
                        resizeVirtualDisplay();
                    } else {
                        createVirtualDisplay();
                    }
                }
            });
        }
    }

    private void createVirtualDisplay() {
        updateSurfaceTextureSize();
        releaseVirtualDisplaySurface();
        virtualDisplaySurface = new Surface(surfaceTextureHelper.getSurfaceTexture());
        virtualDisplay = mediaProjection.createVirtualDisplay(
                "WebRTC_ScreenCapture",
                width,
                height,
                VIRTUAL_DISPLAY_DPI,
                DISPLAY_FLAGS,
                virtualDisplaySurface,
                null,
                null);
    }

    private void resizeVirtualDisplay() {
        updateSurfaceTextureSize();
        virtualDisplay.resize(width, height, VIRTUAL_DISPLAY_DPI);
        final Surface oldSurface = virtualDisplaySurface;
        virtualDisplaySurface = new Surface(surfaceTextureHelper.getSurfaceTexture());
        virtualDisplay.setSurface(virtualDisplaySurface);
        if (oldSurface != null) {
            oldSurface.release();
        }
    }

    private void updateSurfaceTextureSize() {
        surfaceTextureHelper.setTextureSize(width, height);
        surfaceTextureHelper.getSurfaceTexture().setDefaultBufferSize(width, height);
    }

    private void releaseVirtualDisplaySurface() {
        if (virtualDisplaySurface != null) {
            virtualDisplaySurface.release();
            virtualDisplaySurface = null;
        }
    }

    /**
     * MediaProjection invokes onStop on SurfaceTextureHelper's handler. Do the
     * equivalent of stopCapture inline: calling stopCapture here would wait for
     * the same handler and deadlock. The system has already stopped the
     * projection, so do not call MediaProjection.stop() a second time.
     */
    private boolean releaseProjectionAfterSystemStop() {
        if (!captureResourcesReleased.compareAndSet(false, true)) {
            return false;
        }
        releaseProjectionResources(false);
        return true;
    }

    /** Runs on SurfaceTextureHelper's handler after either cleanup path wins. */
    private void releaseProjectionResources(boolean stopProjection) {
        surfaceTextureHelper.stopListening();
        capturerObserver.onCapturerStopped();
        if (virtualDisplay != null) {
            virtualDisplay.release();
            virtualDisplay = null;
        }
        releaseVirtualDisplaySurface();
        final MediaProjection activeProjection = mediaProjection;
        mediaProjection = null;
        if (stopProjection && activeProjection != null) {
            // A local stop must not masquerade as an Android revoke.
            activeProjection.unregisterCallback(mediaProjectionCallback);
            activeProjection.stop();
        }
    }

    private void emitScreenCaptureStopped() {
        final FlutterWebRTCPlugin plugin = FlutterWebRTCPlugin.sharedSingleton;
        if (plugin == null) {
            return;
        }
        final Map<String, Object> event = new HashMap<>();
        event.put("event", "onScreenCaptureStopped");
        plugin.sendEvent(event);
    }

    @Override
    public boolean isScreencast() {
        return true;
    }

    public long getNumCapturedFrames() {
        return numCapturedFrames;
    }
}
