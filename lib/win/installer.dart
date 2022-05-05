import 'dart:io';

import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';

class Installer
{
  static Future<String> getDependenciesLocationDir() async{
    Directory appDocDir = await getApplicationSupportDirectory();
    if(Platform.isWindows){
      return appDocDir.path+"\\";
    }
    return appDocDir.path+"/";
  }

  static Future<bool> copyAssetToFilesystem(String assetPath, String destination) async{
    ByteData data = await rootBundle.load(assetPath);
    List<int> bytes = data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes);
    var file = await File(destination).writeAsBytes(bytes);
    return file.exists();
  }

  static Future<bool> unpackDependencies() async{
    bool result = false;
    if(Platform.isWindows){
      String winAssets = "packages/mic_stream/assets/installer/win";
      String destination = await getDependenciesLocationDir();
      result |= await copyAssetToFilesystem("$winAssets/portaudio_x64.dll",
          "$destination\\portaudio_x64.dll");
      result |= await copyAssetToFilesystem("$winAssets/portaudio_helper.dll",
          "$destination\\port_audio_helper_x64.dll");
    }
    return result;
  }

  static Future<bool> install() async{
    return await unpackDependencies();
  }
}