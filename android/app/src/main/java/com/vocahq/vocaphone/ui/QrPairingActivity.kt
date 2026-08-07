package com.vocahq.vocaphone.ui

import android.Manifest
import android.content.Intent
import android.content.pm.PackageManager
import android.os.Bundle
import android.util.Size
import androidx.activity.ComponentActivity
import androidx.activity.result.contract.ActivityResultContracts
import androidx.camera.core.CameraSelector
import androidx.camera.core.ImageAnalysis
import androidx.camera.core.ImageProxy
import androidx.camera.core.Preview
import androidx.camera.core.resolutionselector.ResolutionSelector
import androidx.camera.core.resolutionselector.ResolutionStrategy
import androidx.camera.lifecycle.ProcessCameraProvider
import androidx.camera.view.PreviewView
import androidx.core.content.ContextCompat
import androidx.lifecycle.Lifecycle
import com.google.zxing.BarcodeFormat
import com.google.zxing.BinaryBitmap
import com.google.zxing.DecodeHintType
import com.google.zxing.PlanarYUVLuminanceSource
import com.google.zxing.ReaderException
import com.google.zxing.common.HybridBinarizer
import com.google.zxing.qrcode.QRCodeReader
import com.vocahq.vocaphone.core.PairingPayload
import java.util.concurrent.Executors
import java.util.concurrent.atomic.AtomicBoolean

/**
 * Full-screen QR scanner used only for gateway pairing. Returns the raw QR text
 * in [EXTRA_RAW] so [PairingPayload] can validate it on the caller's side.
 *
 * Decoding uses ZXing rather than ML Kit: ML Kit's barcode-scanning artifact
 * fetches its model through Google Play Services at runtime, which is
 * unavailable on GMS-less/microG ROMs and crashes there. ZXing decodes QR
 * codes directly from camera frames, ships fully inside the APK, and needs
 * no device services at all.
 */
class QrPairingActivity : ComponentActivity() {

    private val cameraExecutor = Executors.newSingleThreadExecutor()
    private val handled = AtomicBoolean(false)
    private val reader = QRCodeReader()
    private val decodeHints = mapOf(DecodeHintType.POSSIBLE_FORMATS to listOf(BarcodeFormat.QR_CODE))
    private lateinit var previewView: PreviewView

    private val permissionLauncher = registerForActivityResult(
        ActivityResultContracts.RequestPermission(),
    ) { granted ->
        if (granted) startCamera() else finishCancelled("Camera permission is required to scan.")
    }

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        previewView = PreviewView(this).apply {
            implementationMode = PreviewView.ImplementationMode.COMPATIBLE
            scaleType = PreviewView.ScaleType.FILL_CENTER
        }
        setContentView(previewView)

        when {
            ContextCompat.checkSelfPermission(this, Manifest.permission.CAMERA) ==
                PackageManager.PERMISSION_GRANTED -> startCamera()
            else -> permissionLauncher.launch(Manifest.permission.CAMERA)
        }
    }

    private fun startCamera() {
        val future = ProcessCameraProvider.getInstance(this)
        future.addListener({
            try {
                val provider = future.get()
                val preview = Preview.Builder().build().also {
                    it.surfaceProvider = previewView.surfaceProvider
                }
                val analysis = ImageAnalysis.Builder()
                    .setBackpressureStrategy(ImageAnalysis.STRATEGY_KEEP_ONLY_LATEST)
                    .setResolutionSelector(
                        ResolutionSelector.Builder()
                            .setResolutionStrategy(
                                ResolutionStrategy(
                                    Size(1280, 720),
                                    ResolutionStrategy.FALLBACK_RULE_CLOSEST_HIGHER_THEN_LOWER,
                                ),
                            )
                            .build(),
                    )
                    .build()

                analysis.setAnalyzer(cameraExecutor, ::analyzeFrame)

                // Some tablets/Chromebooks only have a front camera; fall back
                // to it instead of failing outright on DEFAULT_BACK_CAMERA.
                val selector = when {
                    provider.hasCamera(CameraSelector.DEFAULT_BACK_CAMERA) -> CameraSelector.DEFAULT_BACK_CAMERA
                    provider.hasCamera(CameraSelector.DEFAULT_FRONT_CAMERA) -> CameraSelector.DEFAULT_FRONT_CAMERA
                    else -> throw IllegalStateException("No camera available on this device.")
                }

                provider.unbindAll()
                provider.bindToLifecycle(this, selector, preview, analysis)
            } catch (error: Exception) {
                finishCancelled(
                    "Couldn't start the camera on this device. Enter the gateway address manually instead.",
                )
            }
        }, ContextCompat.getMainExecutor(this))
    }

    private fun analyzeFrame(imageProxy: ImageProxy) {
        if (handled.get() || !lifecycle.currentState.isAtLeast(Lifecycle.State.STARTED)) {
            imageProxy.close()
            return
        }
        try {
            val width = imageProxy.width
            val height = imageProxy.height
            val luminance = extractLuminance(imageProxy.planes[0], width, height)
            val source = PlanarYUVLuminanceSource(luminance, width, height, 0, 0, width, height, false)
            val result = reader.decode(BinaryBitmap(HybridBinarizer(source)), decodeHints)
            if (handled.compareAndSet(false, true)) {
                when (val parsed = PairingPayload.parse(result.text)) {
                    is PairingPayload.Result.Ok -> {
                        setResult(
                            RESULT_OK,
                            Intent().putExtra(EXTRA_RAW, result.text)
                                .putExtra(EXTRA_URL, parsed.parsed.url)
                                .putExtra(EXTRA_TOKEN, parsed.parsed.token),
                        )
                        finish()
                    }
                    is PairingPayload.Result.Err -> {
                        // Keep scanning; not a VocaPhone pairing code.
                        handled.set(false)
                    }
                }
            }
        } catch (_: ReaderException) {
            // No QR code decoded in this frame; keep scanning.
        } finally {
            reader.reset()
            imageProxy.close()
        }
    }

    /** Copies the Y (luminance) plane into a packed, row-stride-free byte array. */
    private fun extractLuminance(plane: ImageProxy.PlaneProxy, width: Int, height: Int): ByteArray {
        val buffer = plane.buffer
        val rowStride = plane.rowStride
        val pixelStride = plane.pixelStride
        if (pixelStride == 1 && rowStride == width) {
            val data = ByteArray(width * height)
            buffer.get(data)
            return data
        }
        val data = ByteArray(width * height)
        val row = ByteArray(rowStride)
        for (y in 0 until height) {
            buffer.position(y * rowStride)
            buffer.get(row, 0, minOf(rowStride, buffer.remaining()))
            for (x in 0 until width) {
                data[y * width + x] = row[x * pixelStride]
            }
        }
        return data
    }

    private fun finishCancelled(message: String) {
        setResult(RESULT_CANCELED, Intent().putExtra(EXTRA_ERROR, message))
        finish()
    }

    override fun onDestroy() {
        super.onDestroy()
        cameraExecutor.shutdown()
    }

    companion object {
        const val EXTRA_RAW = "pairing_raw"
        const val EXTRA_URL = "pairing_url"
        const val EXTRA_TOKEN = "pairing_token"
        const val EXTRA_ERROR = "pairing_error"
    }
}
