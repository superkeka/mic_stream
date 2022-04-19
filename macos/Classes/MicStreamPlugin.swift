import Cocoa
import FlutterMacOS


//import UIKit
import AVFoundation
import Dispatch

enum AudioFormat : Int { case ENCODING_PCM_8BIT=3, ENCODING_PCM_16BIT=2 }
enum ChannelConfig : Int { case CHANNEL_IN_MONO=16	, CHANNEL_IN_STEREO=12 }
enum AudioSource : Int { case DEFAULT }

public class SwiftMicStreamPlugin: NSObject, FlutterStreamHandler, FlutterPlugin, AVCaptureAudioDataOutputSampleBufferDelegate {
    public static func register(with registrar: FlutterPluginRegistrar) {
        let channel = FlutterEventChannel(name:"aaron.code.com/mic_stream", binaryMessenger: registrar.messenger)
        let methodChannel = FlutterMethodChannel(name: "aaron.code.com/mic_stream_method_channel", binaryMessenger: registrar.messenger)
        let instance = SwiftMicStreamPlugin()
        channel.setStreamHandler(instance);
        registrar.addMethodCallDelegate(instance, channel: methodChannel)
    }

    let isRecording:Bool = false;
    var CHANNEL_CONFIG:ChannelConfig = ChannelConfig.CHANNEL_IN_MONO;
    var SAMPLE_RATE:Int = 44100; // this is the sample rate the user wants
    var actualSampleRate:Float64?; // this is the actual hardware sample rate the device is using
    var AUDIO_FORMAT:AudioFormat = AudioFormat.ENCODING_PCM_16BIT; // this is the encoding/bit-depth the user wants
    var actualBitDepth:UInt32?; // this is the actual hardware bit-depth
    var AUDIO_SOURCE:AudioSource = AudioSource.DEFAULT;
    var BUFFER_SIZE = 4096;
    var eventSink:FlutterEventSink?;
    var session : AVCaptureSession!
    var UID : String!
    var aggregateDeviceID: AudioDeviceID = 0
    
    public func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
        switch call.method {
            case "setUid":
                if let args = call.arguments as? Dictionary<String, Any>,
                    let uid = args["uid"] as? String {
                    print("UID")
                    print(uid)
                    UID = uid;
                    result(0)
                } else {
                    result(FlutterError.init(code: "bad args", message: nil, details: nil))
                }
                break;
            case "getDevices":
                result(getDevices())
                break;
            case "requestMicrophoneAccess":
                result(requestMicrophoneAccess())
                break;
            case "createMultiOutputDevice":
                if let args = call.arguments as? Dictionary<String, Any>,
                   let masterUid = args["masterUID"] as? String,
                   let secondUid = args["secondUID"] as? String,
                   let multiOutUID = args["multiOutUID"] as? String
                {
                    let res = createMultiOutputAudioDevice(masterDeviceUID: masterUid as CFString, secondDeviceUID: secondUid as CFString, multiOutUID: multiOutUID)
                    setDefaultOutputDevice(devId: res.1)
                    result(0)
                } else {
                    result(FlutterError.init(code: "bad args", message: nil, details: nil))
                }
                
                break;
            case "destroyMultiOutputDevice":
                AudioHardwareDestroyAggregateDevice(aggregateDeviceID);
                result(0)
                break;
            case "getSampleRate":
                result(self.actualSampleRate)
                break;
            case "getBitDepth":
                result(self.actualBitDepth)
                break;
            case "getBufferSize":
                result(self.BUFFER_SIZE)
                break;
            default:
                result(FlutterMethodNotImplemented)
        }
    }
    
    public func requestMicrophoneAccess() -> Bool{
        var status = false;
        if #available(macOS 10.14, *) {
            switch AVCaptureDevice.authorizationStatus(for: .audio) {
            case .authorized: // The user has previously granted access to the camera.
                return true
                
            case .notDetermined: // The user has not yet been asked for camera access.
                AVCaptureDevice.requestAccess(for: .audio) { granted in
                    if granted {
                        status = true
                    }
                }
                
            case .denied: // The user has previously denied access.
                return false
                
            case .restricted: // The user can't grant access due to restrictions.
                return false
            }
        } else {
            // Fallback on earlier versions
        }
        return status
    }
    
    public func onCancel(withArguments arguments:Any?) -> FlutterError?  {
        self.session?.stopRunning()
        return nil
    }

    public func onListen(withArguments arguments: Any?, eventSink events: @escaping FlutterEventSink) -> FlutterError? {
        NSLog("ON LISTEN CALLED................... *"); 
        if (isRecording) {
            return nil;
        }
    
        let config = arguments as! [Int?];
        // Set parameters, if available
        print(config);
        switch config.count {
            case 4:
                AUDIO_FORMAT = AudioFormat(rawValue:config[3]!)!;
                fallthrough
            case 3:
                CHANNEL_CONFIG = ChannelConfig(rawValue:config[2]!)!;
                if(CHANNEL_CONFIG != ChannelConfig.CHANNEL_IN_MONO) {
                    events(FlutterError(code: "-3",
                                                          message: "Currently only ChannelConfig CHANNEL_IN_MONO is supported", details:nil))
                    return nil
                }
                fallthrough
            case 2:
                SAMPLE_RATE = config[1]!;
                fallthrough
            case 1:
                AUDIO_SOURCE = AudioSource(rawValue:config[0]!)!;
                if(AUDIO_SOURCE != AudioSource.DEFAULT) {
                    events(FlutterError(code: "-3",
                                        message: "Currently only default AUDIO_SOURCE (id: 0) is supported", details:nil))
                    return nil
                }
            default:
                events(FlutterError(code: "-3",
                                  message: "At least one argument (AudioSource) must be provided ", details:nil))
                return nil
        }
        NSLog("Setting eventSinkn: \(config.count)");
        self.eventSink = events;
        startCapture();
        return nil;
    }
    
    func startCapture() {
        if let audioCaptureDevice : AVCaptureDevice = UID == "" ? AVCaptureDevice.default(for:AVMediaType.audio) : AVCaptureDevice.init(uniqueID: UID){

            self.session = AVCaptureSession()
            do {
                try audioCaptureDevice.lockForConfiguration()
                
                let audioInput = try AVCaptureDeviceInput(device: audioCaptureDevice)
                audioCaptureDevice.unlockForConfiguration()

                if(self.session.canAddInput(audioInput)){
                    self.session.addInput(audioInput)
                }
                
                
                //let numChannels = CHANNEL_CONFIG == ChannelConfig.CHANNEL_IN_MONO ? 1 : 2
                // setting the preferred sample rate on AVAudioSession  doesn't magically change the sample rate for our AVCaptureSession
                // try AVAudioSession.sharedInstance().setPreferredSampleRate(Double(SAMPLE_RATE))
 
                // neither does setting AVLinearPCMBitDepthKey on audioOutput.audioSettings (unavailable on iOS)
                // 99% sure it's not possible to set streaming sample rate/bitrate
                // try AVAudioSession.sharedInstance().setPreferredOutputNumberOfChannels(numChannels)
                let audioOutput = AVCaptureAudioDataOutput()
                audioOutput.setSampleBufferDelegate(self, queue: DispatchQueue.global())
              
                if(self.session.canAddOutput(audioOutput)){
                    self.session.addOutput(audioOutput)
                }

                DispatchQueue.main.async {
                    self.session.startRunning()
                }
            } catch let e {
                self.eventSink!(FlutterError(code: "-3",
                             message: "Error encountered starting audio capture, see details for more information.", details:e))
            }
        }
    }
    
    public func captureOutput(_            output      : AVCaptureOutput,
                   didOutput    sampleBuffer: CMSampleBuffer,
                   from         connection  : AVCaptureConnection) {	

				let format = CMSampleBufferGetFormatDescription(sampleBuffer)!
				let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(format)!.pointee

				let nChannels = Int(asbd.mChannelsPerFrame) // probably 2
				let bufferlistSize = AudioBufferList.sizeInBytes(maximumBuffers: nChannels)
				let audioBufferList = AudioBufferList.allocate(maximumBuffers: nChannels)
				for i in 0..<nChannels {
						audioBufferList[i] = AudioBuffer(mNumberChannels: 0, mDataByteSize: 0, mData: nil)
				}

				var block: CMBlockBuffer?
				let status = CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(sampleBuffer, bufferListSizeNeededOut: nil, bufferListOut: audioBufferList.unsafeMutablePointer, bufferListSize: bufferlistSize, blockBufferAllocator: nil, blockBufferMemoryAllocator: nil, flags: 0, blockBufferOut: &block)
				if (noErr != status) {
					NSLog("we hit an error!!!!!! \(status)")
					return;
				}

        if(audioBufferList.unsafePointer.pointee.mBuffers.mData == nil) {
            return
        }
        
        if(self.actualSampleRate == nil) {
            //let fd = CMSampleBufferGetFormatDescription(sampleBuffer)
            //let asbd:UnsafePointer<AudioStreamBasicDescription>? = CMAudioFormatDescriptionGetStreamBasicDescription(fd!)
            self.actualSampleRate = asbd.mSampleRate
            self.actualBitDepth = asbd.mBitsPerChannel
        }
        
        let data = Data(bytesNoCopy: audioBufferList.unsafePointer.pointee.mBuffers.mData!, count: Int(audioBufferList.unsafePointer.pointee.mBuffers.mDataByteSize), deallocator: .none)
        self.eventSink!(FlutterStandardTypedData(bytes: data))

    }

    public func getDevices() -> Array<Array<String>>{
        let devices = AVCaptureDevice.devices(for: .audio)
        var ids: [Array<String>] = []
        for device in devices {
            let device: [String] = [ device.uniqueID, device.localizedName, "IN"]
            ids.append(device)
        }
        let outputDevices = AudioDeviceFinder.findDevices()
        for device in outputDevices {
            let device: [String] = [ device.uid ?? "", device.name ?? "", "OUT"]
            ids.append(device)
        }
        return ids
    }
    
    func createMultiOutputAudioDevice(masterDeviceUID: CFString, secondDeviceUID: CFString, multiOutUID: String) -> (OSStatus, AudioDeviceID) {
        let desc: [String : Any] = [
                kAudioAggregateDeviceNameKey: "Inturo Output Device",
                kAudioAggregateDeviceUIDKey: multiOutUID,
                kAudioAggregateDeviceSubDeviceListKey: [[kAudioSubDeviceUIDKey: masterDeviceUID], [kAudioSubDeviceUIDKey: secondDeviceUID]],
                kAudioAggregateDeviceMasterSubDeviceKey: masterDeviceUID,
                kAudioAggregateDeviceIsStackedKey: 1,
            ]
        let dev = AudioHardwareCreateAggregateDevice(desc as CFDictionary, &aggregateDeviceID)
        
        return (dev, aggregateDeviceID)
    }
    
    func setDefaultOutputDevice(devId: AudioDeviceID) -> OSStatus{
        var pointer = devId
        var address = AudioObjectPropertyAddress(
          mSelector: kAudioHardwarePropertyDefaultOutputDevice,
          mScope: kAudioObjectPropertyScopeGlobal,
          mElement: kAudioObjectPropertyElementMaster)
        let statusCode = AudioObjectSetPropertyData(
          AudioObjectID(kAudioObjectSystemObject),
          &address,
          0,
          nil,
          UInt32(MemoryLayout<AudioDeviceID>.size),
          &pointer
        )
        return statusCode
    }


}

class AudioDevice {
    var audioDeviceID:AudioDeviceID

    init(deviceID:AudioDeviceID) {
        self.audioDeviceID = deviceID
    }

    var hasOutput: Bool {
        get {
            var address:AudioObjectPropertyAddress = AudioObjectPropertyAddress(
                mSelector:AudioObjectPropertySelector(kAudioDevicePropertyStreamConfiguration),
                mScope:AudioObjectPropertyScope(kAudioDevicePropertyScopeOutput),
                mElement:0)

            var propsize:UInt32 = UInt32(MemoryLayout<CFString?>.size);
            var result:OSStatus = AudioObjectGetPropertyDataSize(self.audioDeviceID, &address, 0, nil, &propsize);
            if (result != 0) {
                return false;
            }

            let bufferList = UnsafeMutablePointer<AudioBufferList>.allocate(capacity:Int(propsize))
            result = AudioObjectGetPropertyData(self.audioDeviceID, &address, 0, nil, &propsize, bufferList);
            if (result != 0) {
                return false
            }

            let buffers = UnsafeMutableAudioBufferListPointer(bufferList)
            for bufferNum in 0..<buffers.count {
                if buffers[bufferNum].mNumberChannels > 0 {
                    return true
                }
            }

            return false
        }
    }

    var uid:String? {
        get {
            var address:AudioObjectPropertyAddress = AudioObjectPropertyAddress(
                mSelector:AudioObjectPropertySelector(kAudioDevicePropertyDeviceUID),
                mScope:AudioObjectPropertyScope(kAudioObjectPropertyScopeGlobal),
                mElement:AudioObjectPropertyElement(kAudioObjectPropertyElementMaster))

            var name:CFString? = nil
            var propsize:UInt32 = UInt32(MemoryLayout<CFString?>.size)
            let result:OSStatus = AudioObjectGetPropertyData(self.audioDeviceID, &address, 0, nil, &propsize, &name)
            if (result != 0) {
                return nil
            }

            return name as String?
        }
    }

    var name:String? {
        get {
            var address:AudioObjectPropertyAddress = AudioObjectPropertyAddress(
                mSelector:AudioObjectPropertySelector(kAudioDevicePropertyDeviceNameCFString),
                mScope:AudioObjectPropertyScope(kAudioObjectPropertyScopeGlobal),
                mElement:AudioObjectPropertyElement(kAudioObjectPropertyElementMaster))

            var name:CFString? = nil
            var propsize:UInt32 = UInt32(MemoryLayout<CFString?>.size)
            let result:OSStatus = AudioObjectGetPropertyData(self.audioDeviceID, &address, 0, nil, &propsize, &name)
            if (result != 0) {
                return nil
            }

            return name as String?
        }
    }
}


class AudioDeviceFinder {
    static func findDevices() -> Array<AudioDevice>{
        var audioDevices: [AudioDevice] = []
        var propsize:UInt32 = 0

        var address:AudioObjectPropertyAddress = AudioObjectPropertyAddress(
            mSelector:AudioObjectPropertySelector(kAudioHardwarePropertyDevices),
            mScope:AudioObjectPropertyScope(kAudioObjectPropertyScopeGlobal),
            mElement:AudioObjectPropertyElement(kAudioObjectPropertyElementMaster))

        var result:OSStatus = AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &address, UInt32(MemoryLayout<AudioObjectPropertyAddress>.size), nil, &propsize)

        if (result != 0) {
            print("Error \(result) from AudioObjectGetPropertyDataSize")
            return audioDevices
        }

        let numDevices = Int(propsize / UInt32(MemoryLayout<AudioDeviceID>.size))

        var devids = [AudioDeviceID]()
        for _ in 0..<numDevices {
            devids.append(AudioDeviceID())
        }

        result = AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &propsize, &devids);
        if (result != 0) {
            print("Error \(result) from AudioObjectGetPropertyData")
            return audioDevices
        }

        for i in 0..<numDevices {
            let audioDevice = AudioDevice(deviceID:devids[i])
            if (audioDevice.hasOutput) {
                audioDevices.append(audioDevice)
                if let name = audioDevice.name,
                    let uid = audioDevice.uid {
                    print("Found device \"\(name)\", uid=\(uid)")
                }
            }
        }
        return audioDevices;
    }
}
