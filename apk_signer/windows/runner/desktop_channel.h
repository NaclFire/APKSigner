#ifndef APK_SIGNER_RUNNER_DESKTOP_CHANNEL_H_
#define APK_SIGNER_RUNNER_DESKTOP_CHANNEL_H_

#include <flutter/flutter_engine.h>

namespace apk_signer {

// 注册 "apk_signer/desktop" 方法通道：
//   getAssetsDir -> 打包资源目录（data/flutter_assets/assets）
//   runHidden    -> CREATE_NO_WINDOW 方式启动进程并捕获 stdout/stderr
void RegisterDesktopChannel(flutter::FlutterEngine* engine);

}  // namespace apk_signer

#endif  // APK_SIGNER_RUNNER_DESKTOP_CHANNEL_H_
