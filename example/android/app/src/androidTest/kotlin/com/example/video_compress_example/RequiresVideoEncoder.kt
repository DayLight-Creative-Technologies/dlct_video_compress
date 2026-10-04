package com.example.video_compress_example

/**
 * [DLCT] A test that runs the device's H.264 encoder. The API 24 emulator's
 * software encoder (libstagefright_soft_avcenc) crashes the media server in
 * motion estimation on every input the tests use (64 x 48 and 1280 x 720:
 * SIGSEGV in ime_evaluate_init_srchposn_16x16), so CI runs these on API 36
 * only (`notAnnotation`), and every other test on both. Android 7 phones
 * encode H.264 in hardware.
 */
@Retention(AnnotationRetention.RUNTIME)
@Target(AnnotationTarget.FUNCTION)
annotation class RequiresVideoEncoder
