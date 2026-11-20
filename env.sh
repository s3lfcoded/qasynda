# Окружение сборки: всё на диске D, системные настройки не меняются.
# Использование в Git Bash:  source /d/Claude/qasynda/env.sh
export PUB_CACHE='D:\flutter-cache\pub'
export GRADLE_USER_HOME='D:\flutter-cache\gradle'
export ANDROID_HOME='D:\android-sdk'
export ANDROID_SDK_ROOT='D:\android-sdk'
export JAVA_HOME='C:\Program Files\Android\Android Studio\jbr'
export FLUTTER_SUPPRESS_ANALYTICS=true
export PATH="/d/flutter/bin:/d/android-sdk/platform-tools:$JAVA_HOME/bin:$PATH"
# Имя пользователя Windows содержит кириллицу, а Java не может открыть служебный сокет
# во временной папке с такими символами — поэтому временная папка тоже на диске D.
export TEMP='D:\flutter-cache\tmp'
export TMP='D:\flutter-cache\tmp'
export JAVA_TOOL_OPTIONS='-Djdk.net.unixdomain.tmpdir=D:\flutter-cache\tmp -Djava.io.tmpdir=D:\flutter-cache\tmp'
