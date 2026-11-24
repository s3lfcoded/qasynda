package kz.qasynda.qasynda

import android.net.Uri
import com.google.mlkit.vision.common.InputImage
import com.google.mlkit.vision.text.TextRecognition
import com.google.mlkit.vision.text.TextRecognizer
import com.google.mlkit.vision.text.latin.TextRecognizerOptions
import io.flutter.embedding.android.FlutterFragmentActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.io.File

// FragmentActivity нужна для системного окна отпечатка и Face Unlock (пакет local_auth).
class MainActivity : FlutterFragmentActivity() {
    private var recognizer: TextRecognizer? = null

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        // Распознавание текста на снимке карты: qasynda/ocr, recognize({path}) → список строк.
        // ML Kit с моделью внутри приложения: без сети. Снимок удаляет само приложение.
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "qasynda/ocr").setMethodCallHandler { call, result ->
            if (call.method != "recognize") {
                result.notImplemented()
                return@setMethodCallHandler
            }
            val path = call.argument<String>("path")
            if (path == null) {
                result.error("bad_args", "path is required", null)
                return@setMethodCallHandler
            }
            val image = try {
                // fromFilePath сам учитывает поворот из EXIF.
                InputImage.fromFilePath(this, Uri.fromFile(File(path)))
            } catch (e: Exception) {
                result.error("ocr_failed", e.message, null)
                return@setMethodCallHandler
            }
            val client = recognizer ?: TextRecognition.getClient(TextRecognizerOptions.DEFAULT_OPTIONS).also { recognizer = it }
            client.process(image)
                .addOnSuccessListener { text ->
                    val lines = ArrayList<String>()
                    for (block in text.textBlocks) {
                        for (line in block.lines) lines.add(line.text)
                    }
                    result.success(lines)
                }
                .addOnFailureListener { e -> result.error("ocr_failed", e.message, null) }
        }
    }

    override fun onDestroy() {
        recognizer?.close()
        recognizer = null
        super.onDestroy()
    }
}
