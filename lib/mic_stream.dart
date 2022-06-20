import 'dart:async';
import 'dart:ffi';

import 'dart:io';
import 'dart:isolate';

import 'package:ffi/ffi.dart';
import 'package:flutter/foundation.dart';
import 'package:mic_stream/win/installer.dart';
import 'package:mic_stream/win/port_audio.dart';
import 'package:permission_handler/permission_handler.dart' as handler;
import 'package:flutter/services.dart';
import 'dart:typed_data';

import 'audio_device.dart';

// In reference to the implementation of the official sensors plugin
// https://github.com/flutter/plugins/tree/master/packages/sensors

enum AudioSource {
  DEFAULT,
  MIC,
  VOICE_UPLINK,
  VOICE_DOWNLINK,
  VOICE_CALL,
  CAMCORDER,
  VOICE_RECOGNITION,
  VOICE_COMMUNICATION,
  REMOTE_SUBMIX,
  UNPROCESSED,
  VOICE_PERFORMANCE,
  AUDIO_LOOPBACK
}
enum ChannelConfig { CHANNEL_IN_MONO, CHANNEL_IN_STEREO }
enum AudioFormat { ENCODING_PCM_8BIT, ENCODING_PCM_16BIT, ENCODING_PCM_32BIT}

class MicStream {
  static const AudioSource _DEFAULT_AUDIO_SOURCE = AudioSource.DEFAULT;
  static const ChannelConfig _DEFAULT_CHANNELS_CONFIG =
      ChannelConfig.CHANNEL_IN_MONO;
  static const AudioFormat _DEFAULT_AUDIO_FORMAT =
      AudioFormat.ENCODING_PCM_8BIT;
  static const int _DEFAULT_SAMPLE_RATE = 16000;

  static const int _MIN_SAMPLE_RATE = 1;
  static const int _MAX_SAMPLE_RATE = 100000;


  static const EventChannel _microphoneEventChannel =
      EventChannel('aaron.code.com/mic_stream');
  static const MethodChannel _microphoneMethodChannel =
      MethodChannel('aaron.code.com/mic_stream_method_channel');

  /// The actual sample rate used for streaming.  This may return zero if invoked without listening to the _microphone Stream
  static Future<double>? _sampleRate;
  static Future<double>? get sampleRate => _sampleRate;

  /// The actual bit depth used for streaming. This may return zero if invoked without listening to the _microphone Stream first.
  static Future<int>? _bitDepth;
  static Future<int>? get bitDepth => _bitDepth;

  static Future<int>? _bufferSize;
  static Future<int>? get bufferSize => _bufferSize;

  static List<bool> channelsInUse = List.filled(8, false);


  // This function manages the permission and ensures you're allowed to record audio
  static Future<bool> get permissionStatus async {
    if(Platform.isMacOS || Platform.isWindows){
      return true;
    }
    var micStatus = await handler.Permission.microphone.request();
    return !micStatus.isDenied;
  }

  /// This function initializes a connection to the native backend (if not already available).
  /// Returns a Uint8List stream representing the captured audio.
  /// IMPORTANT - on iOS, there is no guarantee that captured audio will be encoded with the requested sampleRate/bitDepth.
  /// You must check the sampleRate and bitDepth properties of the MicStream object *after* invoking this method (though this does not need to be before listening to the returned stream).
  /// This is why this method returns a Uint8List - if you request a 16-bit encoding, you will need to check that
  /// the returned stream is actually returning 16-bit data, and if so, manually cast uint8List.buffer.asUint16List()
  /// audioSource:     The device used to capture audio. The default let's the OS decide.
  /// sampleRate:      The amount of samples per second. More samples give better quality at the cost of higher data transmission
  /// channelConfig:   States whether audio is mono or stereo
  /// audioFormat:     Switch between 8- and 16-bit PCM streams
  ///
  static Future<Stream<Uint8List>?> microphone(
      {AudioSource audioSource: _DEFAULT_AUDIO_SOURCE,
      int sampleRate: _DEFAULT_SAMPLE_RATE,
      ChannelConfig channelConfig: _DEFAULT_CHANNELS_CONFIG,
      AudioFormat audioFormat: _DEFAULT_AUDIO_FORMAT,
      String uid: "",
      Function? onDefaultSourceChanged}) async {
    if (sampleRate < _MIN_SAMPLE_RATE || sampleRate > _MAX_SAMPLE_RATE)
      throw (RangeError.range(sampleRate, _MIN_SAMPLE_RATE, _MAX_SAMPLE_RATE));
    if (!(await permissionStatus))
      throw (PlatformException);
    /// The configured microphone stream;
    Stream<Uint8List>? _microphone;
    if(Platform.isMacOS){
      await _microphoneMethodChannel.invokeMethod("setUid",<String, dynamic>{
        'uid': uid,
      });
    }
    if(!Platform.isWindows) {
      _microphone = _microphone ??
          _microphoneEventChannel.receiveBroadcastStream([
            audioSource.index,
            sampleRate,
            channelConfig == ChannelConfig.CHANNEL_IN_MONO ? 16 : 12,
            audioFormat == AudioFormat.ENCODING_PCM_8BIT ? 3 : 2
          ]).cast<Uint8List>();
    }

    // sampleRate/bitDepth should be populated before any attempt to consume the stream externally.
    // configure these as Completers and listen to the stream internally before returning
    // these will complete only when this internal listener is called
    StreamSubscription<Uint8List>? listener;
    var sampleRateCompleter = new Completer<double>();
    var bitDepthCompleter = new Completer<int>();
    var bufferSizeCompleter = new Completer<int>();
    _sampleRate = sampleRateCompleter.future;
    _bitDepth = bitDepthCompleter.future;
    _bufferSize = bufferSizeCompleter.future;
    if(Platform.isWindows){
      AudioDevice? ad;
      if( audioSource == AudioSource.AUDIO_LOOPBACK ||
          audioSource == AudioSource.DEFAULT ||
          audioSource == AudioSource.MIC && uid == "")
      {
        ad = await getDefaultDevice(audioSource);
        uid = ad!.Uid;
      }
      final Pointer<StreamParameters> p = calloc<StreamParameters>();
      const int bufferSize = 256;
      var receivePort = ReceivePort();
      var stream = Pointer<Pointer<Void>>.fromAddress(malloc<IntPtr>().address);
      var inputChannelsCount = 1;
      int result = 0;

      final pChannelNumberInt = calloc<Int32>();
      var indexChannel = channelsInUse.indexOf(false);
      channelsInUse[indexChannel] = true;
      pChannelNumberInt.value = indexChannel;
      final pChannelNumber = pChannelNumberInt.cast<Void>();
      if(uid == ""){
        var inputDevice = PortAudio.getDefaultInputDevice();
        var inputDeviceInfo = PortAudio.getDeviceInfo(inputDevice);
        sampleRateCompleter.complete(inputDeviceInfo.defaultSampleRate.toDouble());
        bitDepthCompleter.complete(2048);
        bufferSizeCompleter.complete(bufferSize);
        result = PortAudio.openDefaultStream(stream, inputChannelsCount, 0,
            SampleFormat.int16, sampleRate.toDouble(),
            bufferSize, receivePort.sendPort, pChannelNumber, indexChannel);
      }
      else {
        var index = int.parse(uid);
        var inputDeviceInfo = PortAudio.getDeviceInfo(index);
        sampleRateCompleter.complete(inputDeviceInfo.defaultSampleRate.toDouble());
        bitDepthCompleter.complete(2048);
        bufferSizeCompleter.complete(bufferSize);
        p.ref.device = index;
        p.ref.channelCount = inputChannelsCount;
        p.ref.sampleFormat = SampleFormat.int16;
        if(inputDeviceInfo != nullptr){
          p.ref.suggestedLatency = inputDeviceInfo.defaultLowInputLatency;
        }
        else {
          p.ref.suggestedLatency = -130.0 / 1000.0;
        }
        result = PortAudio.openStream(stream, p, nullptr,
            inputDeviceInfo.defaultSampleRate.toDouble(), bufferSize,
            StreamFlags.clipOff | StreamFlags.ditherOff, receivePort.sendPort, pChannelNumber, pChannelNumberInt.value);
        if(result == -9996 || result == -9998){
          //WASAPI BUG WITH MONO
          p.ref.channelCount = inputDeviceInfo.maxInputChannels;
          inputChannelsCount = inputDeviceInfo.maxInputChannels;
          result = PortAudio.openStream(stream, p, nullptr,
              inputDeviceInfo.defaultSampleRate.toDouble(), bufferSize,
              StreamFlags.clipOff | StreamFlags.ditherOff, receivePort.sendPort, pChannelNumber, pChannelNumberInt.value);
        }
      }

      if(result < 0){
        var err = PortAudio.getErrorText(result);
        throw Exception("$err Code: $result Channels: ${inputChannelsCount}");
      }
      if(inputChannelsCount > 2){
        throw Exception("inputChannelsCount > 2 is not supported");
      }
      bool closeRequest = false;
      StreamController<Uint8List> controller;
      controller = StreamController<Uint8List>.broadcast(
          onCancel: (){
            print("onCancel: $result");
            if(result == 0){
              closeRequest = true;

              Future.delayed(Duration(milliseconds: 500),(){
                channelsInUse[indexChannel] = false;
                result = PortAudio.abortStream(stream);
                print("stopStream: $result");
                print("Stream status: ${PortAudio.isStreamStopped(stream)}");
              });
            }
          }
      );

      startDeviceChangedPooling(ad!.Name, audioSource, stream,(){
        if(onDefaultSourceChanged != null){
          onDefaultSourceChanged();
        }
      });

      result = PortAudio.setStreamFinishedCallback(stream, receivePort.sendPort, pChannelNumberInt.value);
      result = PortAudio.startStream(stream);

      _microphone = controller.stream;
      receivePort.listen((message) {
        final translatedMessage = MessageTranslator(message);
        final messageType = translatedMessage.messageType;
        if(messageType == 0){

          if(onDefaultSourceChanged != null){
            print("Stream stop. Callback invoked");
            onDefaultSourceChanged();
          }
          else{
            print("Stream stop.");
          }
          return;
        }
        final frameCount = translatedMessage.frameCount;
        var byteData = ByteData(sizeOf<Int16>()*bufferSize);
        if(inputChannelsCount == 2){
          final outputPointer = translatedMessage.inputPointer?.cast<Int32>();
          for(var i = 0; messageType == MessageTranslator.messageTypeCallback && i < frameCount!; i++) {
            byteData.setInt16(i*(sizeOf<Int16>()), outputPointer![i], Endian.little);
          }
        }
        else if(inputChannelsCount == 1){
          final outputPointer = translatedMessage.inputPointer?.cast<Int16>();
          for(var i = 0; messageType == MessageTranslator.messageTypeCallback && i < frameCount!; i++) {
            byteData.setInt16(i*(sizeOf<Int16>()), outputPointer![i], Endian.little);
          }
        }
        var bytes = byteData.buffer.asUint8List();
        controller.add(bytes);
        if(!closeRequest){
          PortAudio.setStreamResult(StreamCallbackResult.continueProcessing, pChannelNumberInt.value);
        }
        else {
          PortAudio.setStreamResult(2, pChannelNumberInt.value);
        }

      });
      return _microphone;
    }


    listener = _microphone?.listen((x) async {
      await listener!.cancel();
      listener = null;
      sampleRateCompleter.complete(await _microphoneMethodChannel
          .invokeMethod("getSampleRate") as double?);
      bitDepthCompleter.complete(
          await _microphoneMethodChannel.invokeMethod("getBitDepth") as int?);
      bufferSizeCompleter.complete(
          await _microphoneMethodChannel.invokeMethod("getBufferSize") as int?);
    });

    return _microphone;
  }

  static Future<void> initialize() async{
    if(Platform.isWindows){
      await Installer.unpackDependencies();
      String? dependencyDir = await Installer.getDependenciesLocationDir();
      PortAudio.initialize(dependencyDir);
    }
  }

  static Future<List<AudioDevice>> getDevices() async{
    List<AudioDevice> devices = [];
    if(Platform.isMacOS){
      var dev = await _microphoneMethodChannel.invokeMethod("getDevices") as List<dynamic>;
      dev.forEach((d) {
        var ad = AudioDevice(d[0],d[1], d[2] == "IN" ? AudioDirection.Input : AudioDirection.Output);
        devices.add(ad);
      });
    }
    else if(Platform.isWindows){
      var r = PortAudio.refreshDeviceListWasapi();
      PortAudio.refreshDeviceList();
      for(int i = 0; i < PortAudio.getDeviceCount(); i++){
        var paDevice = PortAudio.getDeviceInfo(i);
        AudioDirection direction =  paDevice.maxOutputChannels > 0 ?
        AudioDirection.Output : AudioDirection.Input;
        var ad = AudioDevice(i.toString(),paDevice.name, direction);
        devices.add(ad);
      }

    }
    return devices;
  }

  static Future<AudioDevice?> getDefaultDevice(AudioSource source) async{
    AudioDevice? dev;
    if(Platform.isWindows){
      var devices = await getDevices();
      ///fallback
      if(devices.length > 0)
      {
        dev = devices[0];
      }
      var result = PortAudio.refreshDeviceList();
      if(source == AudioSource.AUDIO_LOOPBACK){
        var odName = PortAudio.PahGetDefaultOutputDevice();
        for(final element in devices){
          if(element.Name.contains(odName) && element.Name.contains("[Loopback]") && element.Direction == AudioDirection.Input){
            dev = element;
            break;
          }
        }
      }
      else if(source == AudioSource.DEFAULT || source == AudioSource.MIC){
        var odName = PortAudio.PahGetDefaultInputDevice();
        devices.forEach((element) {
          for(final element in devices){
            if(element.Name.contains(odName)  && element.Direction == AudioDirection.Input){
              dev = element;
              break;
            }
          }
        });

      }
    }
    return dev;
  }

  static void startDeviceChangedPooling(String uid, AudioSource source, Pointer<Pointer<Void>> stream, Function onDeviceChanged) {
    Timer.periodic(Duration(seconds: 5), (timer) async{
      var streamStatus = PortAudio.isStreamStopped(stream);
      if(streamStatus == 1){
        timer.cancel();
      }
      var currentUid =  await getDefaultDevice(source);
      if(uid != currentUid!.Name){
        timer.cancel();
        onDeviceChanged();
      }
    });
  }


  ///Only for MacOS
  static Future<AudioDevice?> createMultiOutputDevice(String masterUID, String secondUID, String multiOutputUID) async{
    AudioDevice audioDev = AudioDevice("", "", AudioDirection.Input);
    if(Platform.isMacOS){
      await _microphoneMethodChannel.invokeMethod("createMultiOutputDevice",<String, dynamic>{
        'masterUID': masterUID,
        'secondUID': secondUID,
        'multiOutUID': multiOutputUID,
      });
      var devices = await getDevices();
      devices.forEach((d) {
        if(d.Uid == multiOutputUID){
          audioDev = d;
        }
      });
      if(audioDev.Uid != ""){
        return audioDev;
      }
    }
    throw Exception("Device is not created");
  }

  static Future<void> destroyMultiOutputDevice() async {
    if (Platform.isMacOS) {
      await _microphoneMethodChannel.invokeMethod(
          "destroyMultiOutputDevice", <String, dynamic>{
          'multiOutUID': "",
      });
    }
  }

  static Future<bool> requestMicrophoneAccess() async {
    if (Platform.isMacOS) {
      return await _microphoneMethodChannel.invokeMethod("requestMicrophoneAccess");
    }
    else
      return false;
  }
}
