import Foundation
import CoreLocation
import os.signpost

let RWA_MAXNUMBEROFPATCHERS = 30
let RWA_MAXNUMBEROFSTEREOPATCHERS = 15;
let RWA_MAXNUMBEROF5CHANNELPATCHERS = 4;
let RWA_MAXNUMBEROFDYNAMICPATCHERS = 50 // currently not in use

// defined as samples/ms
// careful: RWA Creator defines it as samples/s (48000)
var sampleRate = 48.0

var activeLoop = 0
var sceneChanged = false
var stateChanged = false
var rwagameloop:RwaGameLoop = RwaGameLoop()
var dynamicPatchCounter = 0;

struct pdPatcher {
    var patcherTag:UnsafeMutableRawPointer
    var isBusy:Bool = false
    var myAsset:RwaAsset
};

class RwaGameLoop:NSObject, PdListener
{
    var dispatcher:PdDispatcher?
    var monoPatchers:[pdPatcher] = []
    var monoPatchersOgg:[pdPatcher] = []
    var stereoPatchers:[pdPatcher] = []
    var stereoPatchersOgg:[pdPatcher] = []
    var binauralMonoPatchers_fabian:[pdPatcher] = []
    var binauralMonoPatchersOgg_fabian:[pdPatcher] = []
    var binauralStereoPatchers_fabian:[pdPatcher] = []
    var binauralStereoPatchersOgg_fabian:[pdPatcher] = []
    var binaural5ChannelPatchers_fabian:[pdPatcher] = []
    var binaural7ChannelPatchers_fabian:[pdPatcher] = []
    
    var dynamicPatchers:[pdPatcher] = []
    var stereoOut:UnsafeMutableRawPointer?
    var isRunning = false
    var assetFolder:String = String();

    // Patchers of superseded background-asset instances, still fading out after "-end";
    // released when their "<tag>-playfinished" arrives (see startBackgroundState / receiveBang).
    // Mirror of RwaRuntime::assetsPendingRelease in the Creator.
    var assetsPendingRelease:[RwaEntity.AssetMapItem] = []

    // Source of the "<tag>-seed" init value (see sendInitValues2pd).
    // Defaults to the platform RNG; Intentionally not mirrored value-for-value
    // with the Creator (RwaRuntime::seedSource): each engine draws its own.
    var seedSource: () -> UInt32 = { UInt32.random(in: 0...UInt32.max) }

    let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "RWA Player", category: "Game Loop")
    
    override init()
    {
        stereoOut = nil
        dispatcher = PdDispatcher()
        PdBase.setDelegate(dispatcher)

        // Put the bundled Pd resources on Pd's search path. The FABIAN HRTF set
        // (fabian_dir256.txt, 38 MB) sits there next to the playback patches, so those
        // find it by being in the same directory - a game's own Pd patcher, opened from
        // the game folder, does not. With the resources on the search path,
        // [rwa_binauralsimple~ 256 fabian_dir256.txt] resolves from any patch and the
        // file no longer has to be shipped inside every game.
        if let resourcePath = Bundle.main.resourcePath {
            PdBase.add(toSearchPath: resourcePath)
        }
        //rwa_binauralrir_tilde_setup();
        rwa_binauralsimple_tilde_setup();
        vas_reverb_tilde_setup();
        freeverb_tilde_setup();
        oggread_tilde_setup();
        
         super.init()
       
        stereoOut = PdBase.openFile("stereoout.pd", path: Bundle.main.resourcePath)
        if stereoOut == nil {
            self.logger.error("Failed to open patch!")
        }
        
        for _ in 0 ..< RWA_MAXNUMBEROFPATCHERS
        {
            var patch:pdPatcher
            patch = pdPatcher.init(patcherTag: PdBase.openFile("rwaplayermonobinaural_fabian.pd", path: Bundle.main.resourcePath) ,  isBusy: false, myAsset: RwaAsset())
            binauralMonoPatchers_fabian.append(patch)
            let tag:Int32 = PdBase.dollarZero(forFile: patch.patcherTag)
            let receivedFromPd:String = "\(tag)-playfinished"
            dispatcher?.add(self, forSource: receivedFromPd)
        }
        
        for _ in 0 ..< RWA_MAXNUMBEROFPATCHERS
        {
            var patch:pdPatcher
            patch = pdPatcher.init(patcherTag: PdBase.openFile("rwaplayermonobinauralogg_fabian.pd", path: Bundle.main.resourcePath) ,  isBusy: false, myAsset: RwaAsset())
            binauralMonoPatchersOgg_fabian.append(patch)
            let tag:Int32 = PdBase.dollarZero(forFile: patch.patcherTag)
            let receivedFromPd:String = "\(tag)-playfinished"
            dispatcher?.add(self, forSource: receivedFromPd)
        }
        
        for _ in 0 ..< RWA_MAXNUMBEROFSTEREOPATCHERS
        {
            var patch:pdPatcher
            patch = pdPatcher.init(patcherTag: PdBase.openFile("rwaplayerstereobinaural_fabian.pd", path: Bundle.main.resourcePath) ,  isBusy: false, myAsset: RwaAsset())
            binauralStereoPatchers_fabian.append(patch)
            let tag:Int32 = PdBase.dollarZero(forFile: patch.patcherTag)
            let receivedFromPd:String = "\(tag)-playfinished"
            dispatcher?.add(self, forSource: receivedFromPd)
        }
        
        for _ in 0 ..< RWA_MAXNUMBEROFSTEREOPATCHERS
        {
            var patch:pdPatcher
            patch = pdPatcher.init(patcherTag: PdBase.openFile("rwaplayerstereobinauralogg_fabian.pd", path: Bundle.main.resourcePath) ,  isBusy: false, myAsset: RwaAsset())
            binauralStereoPatchersOgg_fabian.append(patch)
            let tag:Int32 = PdBase.dollarZero(forFile: patch.patcherTag)
            let receivedFromPd:String = "\(tag)-playfinished"
            dispatcher?.add(self, forSource: receivedFromPd)
        }
        
        for _ in 0 ..< RWA_MAXNUMBEROF5CHANNELPATCHERS
        {
            var patch:pdPatcher
            patch = pdPatcher.init(patcherTag: PdBase.openFile("rwaplayer5_1channelbinaural_fabian.pd", path: Bundle.main.resourcePath) ,  isBusy: false, myAsset: RwaAsset())
            binaural5ChannelPatchers_fabian.append(patch)
            let tag:Int32 = PdBase.dollarZero(forFile: patch.patcherTag)
            let receivedFromPd:String = "\(tag)-playfinished"
            dispatcher?.add(self, forSource: receivedFromPd)
        }
        
        for _ in 0 ..< RWA_MAXNUMBEROF5CHANNELPATCHERS
        {
            var patch:pdPatcher
            patch = pdPatcher.init(patcherTag: PdBase.openFile("rwaplayer7channelbinaural_fabian.pd", path: Bundle.main.resourcePath) ,  isBusy: false, myAsset: RwaAsset())
            binaural7ChannelPatchers_fabian.append(patch)
            let tag:Int32 = PdBase.dollarZero(forFile: patch.patcherTag)
            let receivedFromPd:String = "\(tag)-playfinished"
            dispatcher?.add(self, forSource: receivedFromPd)
        }
        
        for _ in 0 ..< RWA_MAXNUMBEROFPATCHERS
        {
            var patch:pdPatcher
            patch = pdPatcher.init(patcherTag: PdBase.openFile("rwaloopplayerstereo.pd", path: Bundle.main.resourcePath) ,  isBusy: false, myAsset: RwaAsset())
            stereoPatchers.append(patch)
            let tag:Int32 = PdBase.dollarZero(forFile: patch.patcherTag)
            let receivedFromPd:String = "\(tag)-playfinished"
            dispatcher?.add(self, forSource: receivedFromPd)
        }
        
        for _ in 0 ..< RWA_MAXNUMBEROFPATCHERS
        {
            var patch:pdPatcher
            patch = pdPatcher.init(patcherTag: PdBase.openFile("rwaloopplayerstereoogg.pd", path: Bundle.main.resourcePath) ,  isBusy: false, myAsset: RwaAsset())
            stereoPatchersOgg.append(patch)
            let tag:Int32 = PdBase.dollarZero(forFile: patch.patcherTag)
            let receivedFromPd:String = "\(tag)-playfinished"
            dispatcher?.add(self, forSource: receivedFromPd)
        }
        
        for _ in 0 ..< RWA_MAXNUMBEROFPATCHERS
        {
            var patch:pdPatcher
            patch = pdPatcher.init(patcherTag: PdBase.openFile("rwaloopplayermono.pd", path: Bundle.main.resourcePath) ,  isBusy: false, myAsset: RwaAsset())
            monoPatchers.append(patch)
            let tag:Int32 = PdBase.dollarZero(forFile: patch.patcherTag)
            let receivedFromPd:String = "\(tag)-playfinished"
            dispatcher?.add(self, forSource: receivedFromPd)
        }
        
        for _ in 0 ..< RWA_MAXNUMBEROFPATCHERS
        {
            var patch:pdPatcher
            patch = pdPatcher.init(patcherTag: PdBase.openFile("rwaloopplayermonoogg.pd", path: Bundle.main.resourcePath) ,  isBusy: false, myAsset: RwaAsset())
            monoPatchersOgg.append(patch)
            let tag:Int32 = PdBase.dollarZero(forFile: patch.patcherTag)
            let receivedFromPd:String = "\(tag)-playfinished"
            dispatcher?.add(self, forSource: receivedFromPd)
        }
    }
    
    func initDynamicPatchers()
    {
        freeDynamicPatchers()
        
        for scene in scenes
        {
            for state in scene.states
            {
                for asset in state.assets
                {
                    if (Int(asset.type) == RWAASSETTYPE_PD && !asset.mute)
                    {
                        var patch:pdPatcher
                        patch = pdPatcher.init(patcherTag: PdBase.openFile(asset.name, path: fullAssetPath) ,  isBusy: false, myAsset: asset)
                       // if(patch.patcherTag != nil)
                        
                        dynamicPatchers.append(patch)
                        self.logger.info("Init Patcher: \(patch.myAsset.name) \(self.dynamicPatchers.count)")
                        let tag:Int32 = PdBase.dollarZero(forFile: patch.patcherTag)
                        let receivedFromPd:String = "\(tag)-playfinished"
                        dispatcher?.add(self, forSource: receivedFromPd)
                        dynamicPatchCounter += 1
                        
                    }
                }
            }
        }
    }
    
    func freeDynamicPatchers()
    {
        for i in 0 ..< dynamicPatchCounter
        {
            dynamicPatchers[i].isBusy = false
            dynamicPatchers[i].myAsset = RwaAsset()
            let tag:Int32 = PdBase.dollarZero(forFile: dynamicPatchers[i].patcherTag)
            let receivedFromPd:String = "\(tag)-playfinished"
            dispatcher?.remove(self, forSource: receivedFromPd)
            self.logger.info("freepatcher");
            PdBase.closeFile(dynamicPatchers[i].patcherTag)
        }
        dynamicPatchers.removeAll();
        dynamicPatchCounter = 0
    }
    
    func findFreePatcher(asset: RwaAsset) ->Int32
    {
        if(Int(asset.type) == RWAASSETTYPE_PD) {
            return findFreeDynamicPatcher(asset: asset) }
        else if( Int(asset.type) == RWAASSETTYPE_OGG)
        {
            switch(asset.playbackType)
            {
                case Int32(RWAPLAYBACKTYPE_MONO):
                    return findFreeMonoPatcherOgg()
                
                case Int32(RWAPLAYBACKTYPE_STEREO):
                    return findFreeStereoPatcherOgg()
                    
                case Int32(RWAPLAYBACKTYPE_BINAURALMONO_FABIAN):
                    return  findFreeBinauralMonoFabianPatcherOgg()
                
                case Int32(RWAPLAYBACKTYPE_BINAURALSTEREO_FABIAN):
                    return  findFreeBinauralStereoFabianPatcherOgg()
                
                default:
                    return -1
            }
        }
        
        else
        {
            switch(asset.playbackType)
            {
                case Int32(RWAPLAYBACKTYPE_MONO):
                    return findFreeMonoPatcher()
                
                case Int32(RWAPLAYBACKTYPE_STEREO):
                    return findFreeStereoPatcher()
                    
                case Int32(RWAPLAYBACKTYPE_BINAURALMONO):
                    return  findFreeBinauralMonoFabianPatcher()
                
                case Int32(RWAPLAYBACKTYPE_BINAURALMONO_FABIAN):
                    return  findFreeBinauralMonoFabianPatcher()
                    
                case Int32(RWAPLAYBACKTYPE_BINAURAL5CHANNEL):
                    return findFreeBinaural5ChannelFabianPatcher()
                
                case Int32(RWAPLAYBACKTYPE_BINAURAL5CHANNEL_FABIAN):
                    return findFreeBinaural5ChannelFabianPatcher()
                
                case Int32(RWAPLAYBACKTYPE_BINAURAL7CHANNEL_FABIAN):
                    return findFreeBinaural7ChannelFabianPatcher()
                
                case Int32(RWAPLAYBACKTYPE_BINAURALSTEREO):
                    return findFreeBinauralStereoFabianPatcher()
                
                case Int32(RWAPLAYBACKTYPE_BINAURALSTEREO_FABIAN):
                    return findFreeBinauralStereoFabianPatcher()
                
                case Int32(RWAPLAYBACKTYPE_NATIVE):
                    
                    if(asset.numberOfChannels == 1) {
                        return findFreeMonoPatcher()
                    }
                    
                    if(asset.numberOfChannels == 2) {
                        return findFreeStereoPatcher()                    }
                
                case Int32(RWAPLAYBACKTYPE_BINAURALAUTO):
                    
                    if(asset.numberOfChannels == 1) {
                        return findFreeBinauralMonoFabianPatcher()
                    }
                    
                    if(asset.numberOfChannels == 2) {
                        return findFreeBinauralStereoFabianPatcher()
                    }
                
                    if(asset.numberOfChannels == 5) {
                        return findFreeBinaural5ChannelFabianPatcher()
                    }
                
                    if(asset.numberOfChannels == 7) {
                        return findFreeBinaural7ChannelFabianPatcher()
                    }
                
                default:
                    return -1
            }
        }
        return -1
    }
    
    func findFreeDynamicPatcher(asset: RwaAsset) ->Int32
    {
        for i in 0 ..< dynamicPatchCounter
        {
            if (asset.name == dynamicPatchers[i].myAsset.name )
            {
                dynamicPatchers[i].isBusy = true
                return PdBase.dollarZero(forFile: dynamicPatchers[i].patcherTag)
            }
        }
        return -1
    }
    
    func findFreeMonoPatcher() ->Int32
    {
        for i in 0 ..< RWA_MAXNUMBEROFPATCHERS
        {
            if !monoPatchers[i].isBusy
            {
                monoPatchers[i].isBusy = true
                return PdBase.dollarZero(forFile: monoPatchers[i].patcherTag)
            }
        }
        return -1
    }
    
    func findFreeMonoPatcherOgg() ->Int32
    {
        for i in 0 ..< RWA_MAXNUMBEROFPATCHERS
        {
            if !monoPatchersOgg[i].isBusy
            {
                monoPatchersOgg[i].isBusy = true
                return PdBase.dollarZero(forFile: monoPatchersOgg[i].patcherTag)
            }
        }
        return -1
    }
    
    func findFreeStereoPatcher() ->Int32
    {
        for i in 0 ..< RWA_MAXNUMBEROFPATCHERS
        {
            if !stereoPatchers[i].isBusy
            {
                stereoPatchers[i].isBusy = true
                return PdBase.dollarZero(forFile: stereoPatchers[i].patcherTag)
            }
        }
        return -1
    }
    
    func findFreeStereoPatcherOgg() ->Int32
    {
        for i in 0 ..< RWA_MAXNUMBEROFPATCHERS
        {
            if !stereoPatchersOgg[i].isBusy
            {
                stereoPatchersOgg[i].isBusy = true
                return PdBase.dollarZero(forFile: stereoPatchersOgg[i].patcherTag)
            }
        }
        return -1
    }
    
    func findFreeBinauralMonoFabianPatcher() -> Int32
    {
        for i in 0 ..< RWA_MAXNUMBEROFPATCHERS
        {
            if !binauralMonoPatchers_fabian[i].isBusy
            {
                binauralMonoPatchers_fabian[i].isBusy = true
                return PdBase.dollarZero(forFile: binauralMonoPatchers_fabian[i].patcherTag)
            }
        }
        
        return -1
    }
    
    func findFreeBinauralMonoFabianPatcherOgg() -> Int32
    {
        for i in 0 ..< RWA_MAXNUMBEROFPATCHERS
        {
            if !binauralMonoPatchersOgg_fabian[i].isBusy
            {
                binauralMonoPatchersOgg_fabian[i].isBusy = true
                return PdBase.dollarZero(forFile: binauralMonoPatchersOgg_fabian[i].patcherTag)
            }
        }
        
        return -1
    }
    
    func findFreeBinauralStereoFabianPatcher() ->Int32
    {
        for i in 0 ..< RWA_MAXNUMBEROFSTEREOPATCHERS
        {
            if !binauralStereoPatchers_fabian[i].isBusy
            {
                binauralStereoPatchers_fabian[i].isBusy = true
                return PdBase.dollarZero(forFile: binauralStereoPatchers_fabian[i].patcherTag)
            }
        }
        return -1
    }
    
    func findFreeBinauralStereoFabianPatcherOgg() ->Int32
    {
        for i in 0 ..< RWA_MAXNUMBEROFSTEREOPATCHERS
        {
            if !binauralStereoPatchersOgg_fabian[i].isBusy
            {
                binauralStereoPatchersOgg_fabian[i].isBusy = true
                return PdBase.dollarZero(forFile: binauralStereoPatchersOgg_fabian[i].patcherTag)
            }
        }
        return -1
    }
    
    func findFreeBinaural5ChannelFabianPatcher() ->Int32
    {
        for i in 0 ..< RWA_MAXNUMBEROF5CHANNELPATCHERS
        {
            if !binaural5ChannelPatchers_fabian[i].isBusy
            {
                binaural5ChannelPatchers_fabian[i].isBusy = true
                return PdBase.dollarZero(forFile: binaural5ChannelPatchers_fabian[i].patcherTag)
            }
        }
        return -1
    }
    
    func findFreeBinaural7ChannelFabianPatcher() ->Int32
    {
        for i in 0 ..< RWA_MAXNUMBEROF5CHANNELPATCHERS
        {
            if !binaural7ChannelPatchers_fabian[i].isBusy
            {
                binaural7ChannelPatchers_fabian[i].isBusy = true
                return PdBase.dollarZero(forFile: binaural7ChannelPatchers_fabian[i].patcherTag)
            }
        }
        return -1
    }
    
    func releasePatcherFromItem(_ entityItem:RwaEntity.AssetMapItem)
    {
        let asset = entityItem.asset
        let patcherTag = entityItem.patcherTag
        let playbackType = asset.playbackType
        
        if(Int(asset.type) == RWAASSETTYPE_PD) {
            dynamicPatchers[getDynamicPatcherIndex(patcherTag)].isBusy = false
        }
        
        else if(Int(asset.type) == RWAASSETTYPE_OGG) {
            switch(playbackType)
            {
                case Int32(RWAPLAYBACKTYPE_MONO):
                    monoPatchersOgg[getMonoPatcherOggIndex(patcherTag)].isBusy = false
                    break
                
                case Int32(RWAPLAYBACKTYPE_STEREO):
                    stereoPatchersOgg[getStereoPatcherOggIndex(patcherTag)].isBusy = false
                    break
                    
                case Int32(RWAPLAYBACKTYPE_BINAURALMONO):
                    binauralMonoPatchersOgg_fabian[getBinauralMonoFabianPatcherOggIndex(patcherTag)].isBusy = false
                    break
                
                case Int32(RWAPLAYBACKTYPE_BINAURALMONO_FABIAN):
                    binauralMonoPatchersOgg_fabian[getBinauralMonoFabianPatcherOggIndex(patcherTag)].isBusy = false
                    break
                    
                case Int32(RWAPLAYBACKTYPE_BINAURALSTEREO):
                    binauralStereoPatchersOgg_fabian[getBinauralStereoFabianPatcherOggIndex(patcherTag)].isBusy = false
                    break
                
                case Int32(RWAPLAYBACKTYPE_BINAURALSTEREO_FABIAN):
                    binauralStereoPatchersOgg_fabian[getBinauralStereoFabianPatcherOggIndex(patcherTag)].isBusy = false
                    break
                
                default: break
            }
        }
        
        else
        {
            switch(playbackType)
            {
                case Int32(RWAPLAYBACKTYPE_NATIVE):
                    
                    if(asset.numberOfChannels == 1) {
                        monoPatchers[getMonoPatcherIndex(patcherTag)].isBusy = false
                    }
                    
                    if(asset.numberOfChannels == 2) {
                        stereoPatchers[getStereoPatcherIndex(patcherTag)].isBusy = false
                    }
                    break
                
                case Int32(RWAPLAYBACKTYPE_BINAURALAUTO):
                    
                    if(asset.numberOfChannels == 1) {
                        binauralMonoPatchers_fabian[getBinauralMonoFabianPatcherIndex(patcherTag)].isBusy = false
                    }
                    
                    if(asset.numberOfChannels == 2) {
                        binauralStereoPatchers_fabian[getBinauralStereoFabianPatcherIndex(patcherTag)].isBusy = false
                    }
                    break
                
                case Int32(RWAPLAYBACKTYPE_MONO):
                    monoPatchers[getMonoPatcherIndex(patcherTag)].isBusy = false
                    break
                
                case Int32(RWAPLAYBACKTYPE_STEREO):
                    stereoPatchers[getStereoPatcherIndex(patcherTag)].isBusy = false
                    break
                    
                case Int32(RWAPLAYBACKTYPE_BINAURALMONO):
                    binauralMonoPatchers_fabian[getBinauralMonoFabianPatcherIndex(patcherTag)].isBusy = false
                    break
                
                case Int32(RWAPLAYBACKTYPE_BINAURALMONO_FABIAN):
                    binauralMonoPatchers_fabian[getBinauralMonoFabianPatcherIndex(patcherTag)].isBusy = false
                    break
                    
                case Int32(RWAPLAYBACKTYPE_BINAURALSTEREO):
                    binauralStereoPatchers_fabian[getBinauralStereoFabianPatcherIndex(patcherTag)].isBusy = false
                    break
                
                case Int32(RWAPLAYBACKTYPE_BINAURALSTEREO_FABIAN):
                    binauralStereoPatchers_fabian[getBinauralStereoFabianPatcherIndex(patcherTag)].isBusy = false
                    break
                
                case Int32(RWAPLAYBACKTYPE_BINAURAL5CHANNEL):
                    binaural5ChannelPatchers_fabian[getBinaural5ChannelFabianPatcherIndex(patcherTag)].isBusy = false
                    break
                
                case Int32(RWAPLAYBACKTYPE_BINAURAL5CHANNEL_FABIAN):
                    binaural5ChannelPatchers_fabian[getBinaural5ChannelFabianPatcherIndex(patcherTag)].isBusy = false
                    break
                
                case Int32(RWAPLAYBACKTYPE_BINAURAL7CHANNEL_FABIAN):
                    binaural7ChannelPatchers_fabian[getBinaural7ChannelFabianPatcherIndex(patcherTag)].isBusy = false
                    break
                
                default: break
            }
        }
    }
    
    func getDynamicPatcherIndex(_ tag:Int32) ->Int
    {
        for i in 0 ..< dynamicPatchCounter
        {
            if (PdBase.dollarZero(forFile: dynamicPatchers[i].patcherTag)  == tag) {
                return i
            }
        }
        return -1
    }
    
    func getMonoPatcherIndex(_ tag:Int32) ->Int
    {
        for i in 0 ..< RWA_MAXNUMBEROFPATCHERS
        {
            if (PdBase.dollarZero(forFile: monoPatchers[i].patcherTag)  == tag) {
                return i
            }
        }
        return -1
    }
    
    func getMonoPatcherOggIndex(_ tag:Int32) ->Int
    {
        for i in 0 ..< RWA_MAXNUMBEROFPATCHERS
        {
            if (PdBase.dollarZero(forFile: monoPatchersOgg[i].patcherTag)  == tag) {
                return i
            }
        }
        return -1
    }
    
    func getStereoPatcherIndex(_ tag:Int32) ->Int
    {
        for i in 0 ..< RWA_MAXNUMBEROFPATCHERS
        {
            if (PdBase.dollarZero(forFile: stereoPatchers[i].patcherTag)  == tag) {
                return i
            }
            
        }
        return -1
    }
    
    func getStereoPatcherOggIndex(_ tag:Int32) ->Int
    {
        for i in 0 ..< RWA_MAXNUMBEROFPATCHERS
        {
            if (PdBase.dollarZero(forFile: stereoPatchersOgg[i].patcherTag)  == tag) {
                return i
            }
        }
        return -1
    }
    
    func getBinauralMonoFabianPatcherIndex(_ tag:Int32) ->Int
    {
        for i in 0 ..< RWA_MAXNUMBEROFPATCHERS
        {
            if (PdBase.dollarZero(forFile: binauralMonoPatchers_fabian[i].patcherTag)  == tag) {
                return i
            }
        }
        return -1
    }
    
    func getBinauralMonoFabianPatcherOggIndex(_ tag:Int32) ->Int
    {
        for i in 0 ..< RWA_MAXNUMBEROFPATCHERS
        {
            if (PdBase.dollarZero(forFile: binauralMonoPatchersOgg_fabian[i].patcherTag)  == tag) {
                return i
            }
        }
        return -1
    }
    
    func getBinauralStereoFabianPatcherIndex(_ tag:Int32) ->Int
    {
        for i in 0 ..< RWA_MAXNUMBEROFSTEREOPATCHERS
        {
            if (PdBase.dollarZero(forFile: binauralStereoPatchers_fabian[i].patcherTag)  == tag) {
                return i
            }
        }
        return -1
    }
    
    func getBinauralStereoFabianPatcherOggIndex(_ tag:Int32) ->Int
    {
        for i in 0 ..< RWA_MAXNUMBEROFSTEREOPATCHERS
        {
            if (PdBase.dollarZero(forFile: binauralStereoPatchersOgg_fabian[i].patcherTag)  == tag) {
                return i
            }
        }
        return -1
    }
    
    func getBinaural5ChannelFabianPatcherIndex(_ tag:Int32) ->Int
    {
        for i in 0 ..< RWA_MAXNUMBEROF5CHANNELPATCHERS
        {
            if (PdBase.dollarZero(forFile: binaural5ChannelPatchers_fabian[i].patcherTag)  == tag) {
                return i
            }
            
        }
        return -1
    }
    
    func getBinaural7ChannelFabianPatcherIndex(_ tag:Int32) ->Int
    {
        for i in 0 ..< RWA_MAXNUMBEROF5CHANNELPATCHERS
        {
            if (PdBase.dollarZero(forFile: binaural7ChannelPatchers_fabian[i].patcherTag)  == tag) {
                return i
            }
            
        }
        return -1
    }
    
    func sendEnd2BackgroundAssets()
    {
        if(!hero.backgroundAssets.isEmpty)
        {
            for entityAsset in hero.backgroundAssets
            {
               let patcherTag = entityAsset.value.patcherTag
               let send2pd = "\(patcherTag)-end"
               PdBase.sendBang(toReceiver: send2pd)
                
                self.logger.info("Send End to Background Asset: \(entityAsset.value.asset.name) with patchertag: \(patcherTag)")
            }
        }
    }
    
    func sendEnd2ActiveAssets()
    {
        if(!hero.activeAssets.isEmpty)
        {
            for entityAsset in hero.activeAssets
            {
                let patcherTag = entityAsset.value.patcherTag
                let send2pd = "\(patcherTag)-end"
                PdBase.sendBang(toReceiver: send2pd)
                
                self.logger.info("Send End to Active Asset: \(entityAsset.value.asset.name) with patchertag: \(patcherTag)")
            }
        }
        
        if(!hero.assets2Unblock.isEmpty)
        {
            for asset in hero.assets2Unblock
            {
                asset.blocked = false
                asset.reachedEndPosition = false
            }
            
            hero.assets2Unblock.removeAll()
        }
    }
    
    /// Master output fade in stereoout.pd: "rwamasterfade" is a `<target> <ms>`
    /// list into a [line~] factor that is independent of the user volume ("rwamainvolume").
    /// Mirrors RwaSimulator::sendMasterFade in the Creator.
    func sendMasterFade(_ target: Float, _ milliseconds: Int)
    {
        PdBase.sendList([target, Float(milliseconds)], toReceiver: "rwamasterfade")
    }

    /// Completes the release protocol for one patcher: cancel a possibly
    /// pending fade, make the fade-out zero-length, and end playback.
    /// Mirrors RwaRuntime::resetPatcher in the Creator.
    func resetPatcher(_ patcherTag: Int32)
    {
        PdBase.sendBang(toReceiver: "\(patcherTag)-free")
        PdBase.send(Float(0), toReceiver: "\(patcherTag)-fadeouttime")
        PdBase.sendBang(toReceiver: "\(patcherTag)-end")
    }

    private func resetPool(_ pool: inout [pdPatcher])
    {
        for i in 0 ..< pool.count
        {
            resetPatcher(PdBase.dollarZero(forFile: pool[i].patcherTag))
            pool[i].isBusy = false
        }
    }

    /// Sweeps every pooled patcher with the release protocol at stop, so no
    /// pending [delay] survives into the next run and switches a patch off
    /// under a fresh asset.
    /// Mirrors RwaRuntime::resetAllPatchers, with one deliberate divergence:
    /// the Creator closes its dynamic patchers on every stop (which frees their
    /// clocks), while the Player keeps them open across start/stop of a loaded
    /// game, so they are swept with the same protocol here. 
    func resetAllPatchers()
    {
        resetPool(&monoPatchers)
        resetPool(&monoPatchersOgg)
        resetPool(&stereoPatchers)
        resetPool(&stereoPatchersOgg)
        resetPool(&binauralMonoPatchers_fabian)
        resetPool(&binauralMonoPatchersOgg_fabian)
        resetPool(&binauralStereoPatchers_fabian)
        resetPool(&binauralStereoPatchersOgg_fabian)
        resetPool(&binaural5ChannelPatchers_fabian)
        resetPool(&binaural7ChannelPatchers_fabian)
        resetPool(&dynamicPatchers)
    }

    func unblockAssets(state: RwaState)
    {
        for asset in state.assets {
            asset.blocked = false
        }
    }
    
    func entityIsWithinArea(_ area: RwaArea, _ offsetType: Int) -> Bool
    {
        var distance:Double
        var radiusInKm:Double
        var areaOffsetInMeters:Double
        var areaOffsetInKm:Double
        
        if(offsetType == RWAAREAOFFSETTYPE_ENTER)
        {
            areaOffsetInKm = area.enterOffset/1000;
            areaOffsetInMeters = area.enterOffset;
        }
        else if(offsetType == RWAAREAOFFSETTYPE_EXIT)
        {
            areaOffsetInKm = area.exitOffset/1000;
            areaOffsetInMeters = area.exitOffset;
        }
        else
        {
            areaOffsetInKm = 0;
            areaOffsetInMeters = 0;
        }
        
        if(area.areaType == Int(RWAAREATYPE_CIRCLE) )
        {
            distance = calculateDistance(hero.coordinates, p2: area.coordinates)
            radiusInKm = Double(area.radius/1000)
            if(distance <= radiusInKm + areaOffsetInKm)
            {
                //print("Within Circle Area")
                return true
            }
        }
        
        if( (area.areaType == Int(RWAAREATYPE_SQUARE)) || (area.areaType == Int(RWAAREATYPE_RECTANGLE))  )
        {
            if(coordinateWithinRectangle(hero.coordinates, area.coordinates, Double(area.width) + areaOffsetInMeters, Double(area.height) + areaOffsetInMeters) ) {
                //print("Within Rect Area")
                return true
            }
        }
        
        if( area.areaType == Int(RWAAREATYPE_POLYGON)  )
        {
            //print("Within Polygon Area?")
            if(area.corners != nil)
            {
                if(offsetType == RWAAREAOFFSETTYPE_ENTER || (area.exitOffset == 0) )
                {
                    if(coordinateWithinPolygon(hero.coordinates, area.corners! )) {
                        return true
                    }
                }
                else
                {
                    if(coordinateWithinPolygon(hero.coordinates, area.exitOffsetCorners! )) {
                        return true
                    }
                }
            }
        }
        
        return false
    }
    
    func setScene(scene: RwaScene)
    {
        self.logger.info("Enter new scene: \(scene.name)")

        // let bg assets of current scene fade out
        sendEnd2BackgroundAssets()

        // release the old state's re-entry latch: the per-tick geographic unblock only
        // scans the current scene, so it would stay latched forever after leaving here
        if let currentState = hero.currentState {
            currentState.blockUntilRadiusHasBeenLeft = false
            self.logger.info("Unblocking state \(currentState.stateName)")
        }

        // switch to the new/first scene
        hero.currentScene = scene
        hero.timeInCurrentScene = 0
        currentScene = scene.name // global var, for display in view?

        // activate fallback
        // if fallback of new scene can be activated, notify active assets of previous state/scene to end
        // (otherwise, active assets stay active until a new state is triggered)
        if !scene.fallbackDisabled {
            if scene.states.isEmpty {
                logger.warning("Scene \(scene.name) has fallback enabled but no states; hero has no current state until a new state is triggered.")
                hero.currentState = nil
            } else {
                let fallback = scene.states[0]
                if !fallback.assets.isEmpty {
                    sendEnd2ActiveAssets()
                }
                hero.currentState = fallback
                hero.timeInCurrentState = 0
            }
        } else {
            hero.currentState = nil
        }

        startBackgroundState()
        sceneChanged = true
        stateChanged = true
        NotificationCenter.default.post(name: NSNotification.Name(rawValue: "Redraw Map"), object: nil)
        NotificationCenter.default.post(name: NSNotification.Name(rawValue: "Update Scene"), object: nil)
        NotificationCenter.default.post(name: NSNotification.Name(rawValue: "Update State"), object: nil)
    }
    
    func setEntityScene()
    {
        // While the hero is still inside the current scene's area, stay. Without this,
        // overlapping scene areas switch back and forth on every tick, each switch
        // ending and restarting the background states.
        // Mirror of RwaRuntime::setEntityScene in the Creator.
        if let currentScene = hero.currentScene, entityIsWithinArea(currentScene, RWAAREAOFFSETTYPE_EXIT) {
            return
        }

        for scene in (scenes)
        {
            if(scene.level == hero.currentScene?.level)
            {
                if(scene != hero.currentScene)
                {
                    if(entityIsWithinArea(scene, RWAAREAOFFSETTYPE_ENTER))
                    {
                        setScene(scene: scene)
                        self.logger.info("Enter Scene with new location: \(String(describing: scene.name))")
                        return;
                    }
                }
            }
        }
    }
    
    func setEntityState()
    {
        var exitState = false
        var state = RwaState()
        var scene = RwaScene();
        var hint = RwaState()
        var newScene = String()
        
        if((hero.currentScene) == nil) {
            return
        }
        
        hero.timeInCurrentState += schedulerRate/1000
        hero.timeInCurrentScene += schedulerRate/1000
        
        // why is this necessary?
        if (fmod(hero.timeInCurrentState, 1) >= 0.01) {
            return;
        }
        else {
            logger.notice("Time in current state: \(Int(hero.timeInCurrentState))")
        }
        
        if(hero.currentState != nil)
        {
            if(hero.timeInCurrentState < (hero.currentState?.minStayTime)!) {
                return;
            }
            
            if(hero.timeInCurrentScene < (hero.currentScene?.minStayTime)!) {
                return;
            }
            
            if(hero.currentState!.leaveOnlyAfterAssetsFinish && !hero.activeAssets.isEmpty) {
                return;
            }
        }
        
        setEntityScene()
        scene = hero.currentScene!;
        
        for state in (hero.currentScene?.states)!
        {
            var enterConditionsFulfilled = true
            let requiredStates = state.requiredStates
            
            if(state.type == Int32(RWASTATETYPE_GPS) && hero.currentState != state && !state.blockUntilRadiusHasBeenLeft)
            {
                if(entityIsWithinArea(state, RWAAREAOFFSETTYPE_ENTER))
                {
                    if(!requiredStates.isEmpty)
                    {
                        for requiredState in requiredStates
                        {
                            if(!hero.visitedStates.contains(requiredState))
                            {
                                enterConditionsFulfilled = false
                                if(state.hintState != "") {
                                    if let hintState = hero.currentScene?.getState(state.hintState) {
                                        hint = hintState
                                    }
                                    else {
                                        self.logger.warning("Hint state '\(state.hintState)' not found in current scene")
                                    }
                                    state.blockUntilRadiusHasBeenLeft = true
                                }
                                
                                break;
                            }
                            else {
                                self.logger.info("found required state")
                            }
                        }
                    }
                    
                    if(state.blockUntilRadiusHasBeenLeft) {
                        enterConditionsFulfilled = false
                    }
                    
                    if(state.enterOnlyOnce)
                    {
                        if(hero.visitedStates.contains(state.stateName)) {
                            enterConditionsFulfilled = false
                        }
                    }
                    
                    if(enterConditionsFulfilled)
                    {
                        stateChanged = true
                        sendEnd2ActiveAssets()
                        state.blockUntilRadiusHasBeenLeft = true
                        hero.currentState = state
                        
                        if(!hero.visitedStates.contains(state.stateName)) {
                            hero.visitedStates.append(state.stateName)
                        }
                        
                        unblockAssets(state: state)
                        hero.timeInCurrentState = 0
                        
                        self.logger.info("Enter State '\(hero.currentState!.stateName)'")
                        NotificationCenter.default.post(name: NSNotification.Name(rawValue: "Update State"), object: nil)
                        
                        break
                    }
                }
            }
        }
        
        for state in (hero.currentScene?.states)!
        {
            if(state.blockUntilRadiusHasBeenLeft)
            {
                if(!entityIsWithinArea(state, RWAAREAOFFSETTYPE_EXIT)) {
                    state.blockUntilRadiusHasBeenLeft = false
                }
            }
        }
         
        let background = hero.currentScene?.backgroundState
        
        if(hero.timeInCurrentScene > (background?.timeOut)! && Int((background?.timeOut)!) > 0)
        {
            newScene = (background?.nextScene)!
            if(newScene != "")
            {
                sendEnd2ActiveAssets()
                exitState = true
            }
        }
        
        if(hero.currentState != nil)
        {
            state = hero.currentState!
            
            if(hero.timeInCurrentState > state.timeOut && state.timeOut > 0)
            {
                sendEnd2ActiveAssets()
                exitState = true
            }
             
            if(state.leaveAfterAssetsFinish && hero.timeInCurrentState > 0)
            {
                if(hero.activeAssets.isEmpty)
                {
                    exitState = true
                    
                    self.logger.info("Leave after Assets Finish")
                }
            }
            
            if(hero.currentState?.type == Int32(RWASTATETYPE_GPS))
            {
                if(!entityIsWithinArea(state, RWAAREAOFFSETTYPE_EXIT))
                {
                    if( (!state.leaveOnlyAfterAssetsFinish && !scene.fallbackDisabled)
                        || state.stateWithinState)
                    {
                        
                        sendEnd2ActiveAssets()
                        exitState = true
                    }
                    else
                    {
                        if(hero.activeAssets.isEmpty)
                        {
                            exitState = true
                        }
                    }
                }
            }
            
            if(hint.stateName != "") {
                exitState = true
            }
        }
        
        if(exitState)
        {
            stateChanged = true
            if(hint.stateName != "")
            {
                let nextState:RwaState = hint
                if(hint != hero.currentState)
                {
                    unblockAssets(state: nextState)
                    hero.currentState = nextState
                    hero.timeInCurrentState = 0
                }
            }
            
            else if(newScene != "" )
            {
                let nextScene:RwaScene = hero.getScene(sceneName: newScene)
                setScene(scene: nextScene)
                
                self.logger.info("Enter Scene after timeout")
            }
            
            else if(state.nextScene != "")
            {
                let nextScene:RwaScene = hero.getScene(sceneName: state.nextScene)
                setScene(scene: nextScene)
                
                self.logger.info("Enter Scene '\(nextScene.name)'")
            }
              
            else if(state.nextState != "")
            {
                if let nextState = hero.currentScene?.getState(state.nextState) {
                    unblockAssets(state: nextState)
                    hero.currentState = nextState
                    hero.timeInCurrentState = 0
                }
                else {
                    self.logger.warning("Next state '\(state.nextState)' not found in current scene")
                }
            }
            else
            {
                if(!scene.fallbackDisabled)
                {
                    hero.currentState = hero.currentScene?.states[0]
                    hero.timeInCurrentState = 0
                    
                    self.logger.info("Enter Fallbackstate")
                }
            }
        }
    }
    
    func calculateAssetChannelParameters(_ asset: RwaAsset, bearing: Double) -> CLLocation
    {
        var dx, dy: Double
        var mainLat, mainLon: CLLocationDegrees
        var tmpLat, tmpLon: CLLocationDegrees
        mainLat = asset.coordinates.latitude
        mainLon = asset.coordinates.longitude
        
        dy = cos(degrees2radians(bearing)) * asset.multiChannelSourceRadius
        dx = sin(degrees2radians(bearing)) * asset.multiChannelSourceRadius
        tmpLat = mainLat + (180/Double.pi) * (dy/6378137)
        tmpLon = mainLon + (180/Double.pi) * (dx/6378137)/cos(mainLat)
        let location:CLLocation = CLLocation(latitude: tmpLat, longitude: tmpLon)
        return location
    }
    
    func sendDistance(_ channel:Int,_ patcherTag:Int, _ distance: Float)
    {
        let pdChannel:Int = channel+1
        let distance2Pd:String = "\(patcherTag)-distance\(pdChannel)"
        PdBase.send(distance, toReceiver: distance2Pd)
    }
    
    func sendBearing(_ channel:Int,_ patcherTag:Int, _ bearing: Float)
    {
        let pdChannel:Int = channel+1
        let bearing2Pd:String = "\(patcherTag)-azimuth\(pdChannel)"
        PdBase.send(bearing, toReceiver: bearing2Pd)
    }
    
    func sendElevation(_ channel:Int,_ patcherTag:Int, _ elevation: Float)
    {
        let pdChannel:Int = channel+1
        let elevation2Pd:String = "\(patcherTag)-elevation\(pdChannel)"
        PdBase.send(elevation, toReceiver: elevation2Pd)
    }
    
    func calculateChannelBearingAndDistance(_ channel:Int, _ asset:RwaAsset)
    {
        var offset = RwaAsset.channelOffsetForPlaybackType(Int(asset.playbackType), channel)
        offset += (360 - asset.rotateOffset) % 360;
        
        if(asset.individuellChannelPosition[channel] == false) {
            var channelRadius = asset.multiChannelSourceRadius
            if asset.playbackType == RWAPLAYBACKTYPE_MONO || asset.playbackType == RWAPLAYBACKTYPE_STEREO {
                channelRadius = 0
            }
            asset.channelCoordinates[channel] = calculateDestination(asset.currentPosition, channelRadius, Double(Int(Float(offset)+asset.currentRotateAngleOffset)%360)) }

        if(asset.fixedAzimuth < 0) {
            asset.channelBearing[channel] = Float(calculateBearing(hero.coordinates, p2: asset.channelCoordinates[channel], headDirection: Double(hero.azimuth)))
        }
        else {
            asset.channelBearing[channel] = Float(asset.fixedAzimuth + Double(offset))
        }
        
        if(asset.fixedDistance < 0)
        {
            if(asset.minDistance == -1) {
                asset.channelDistance[channel] = Float(calculateDistance(hero.coordinates, p2: asset.channelCoordinates[channel])) * 1000}
            else
            {
                asset.channelDistance[channel] = Float(calculateDistance(hero.coordinates, p2: asset.channelCoordinates[channel])) * 1000
                if(asset.channelDistance[channel] < Float(asset.minDistance)) {
                    asset.channelDistance[channel] = Float(asset.minDistance)
                 }
            }
        }
        else {
            asset.channelDistance[channel] = Float(asset.fixedDistance)
        }
    }
    
    func sendData2Asset(mapItem: RwaEntity.AssetMapItem)
    {
        var intPatcherTag: Int
        var end2Pd: String
        var lon2Pd: String
        var lat2Pd: String
        var step2Pd: String
        var asset: RwaAsset
        
        asset = mapItem.asset
        intPatcherTag = Int(mapItem.patcherTag)
        lon2Pd = "\(intPatcherTag)-lon"
        lat2Pd = "\(intPatcherTag)-lat"
        step2Pd = "\(intPatcherTag)-step"
         
        if(Int(asset.type) == RWAASSETTYPE_PD)
        {
            PdBase.send(hero.coordinates.longitude, toReceiver: lon2Pd)
            PdBase.send(hero.coordinates.latitude, toReceiver: lat2Pd)
        }

        if(Int(asset.type) == RWAASSETTYPE_PD && !asset.headtrackerRelative2Source)
        {
            // The patch spatialises on its own from the raw head orientation:
            // one set of data, azimuth/elevation are the head values, not source-relative.
            calculateChannelBearingAndDistance(0, asset)
            let totalDistance = calculateDistanceWithAltitude(Double(asset.channelDistance[0]), p2: Double(asset.elevation))
            sendDistance(0, intPatcherTag , Float(totalDistance))
            sendBearing(0, intPatcherTag , Float(azimuth))
            sendElevation(0, intPatcherTag , Float(elevation))
        }
        else
        {
            let numChannels = asset.playbackChannelCount()

            for i in 0 ..< numChannels
            {
                calculateChannelBearingAndDistance(i, asset)
                let channelElevation = calculateElevationEasy(hero.coordinates, p2: asset.channelCoordinates[i], elevation: Double(asset.elevation), headDirection: Double(hero.elevation))
                let totalDistance = calculateDistanceWithAltitude(Double(asset.channelDistance[i]), p2: Double(asset.elevation))
                sendDistance(i, intPatcherTag , Float(totalDistance))
                sendBearing(i, intPatcherTag , asset.channelBearing[i])
                sendElevation(i, intPatcherTag , Float(channelElevation))
            }
        }

        if(Int(asset.type) == RWAASSETTYPE_PD)
        {
            if(stepCount != lastStep)
            {
                lastStep = stepCount
                PdBase.sendBang(toReceiver: step2Pd)
                self.logger.info("STEP to Pd")
            }
        }
        
        if(!asset.reachedEndPosition)
        {
            if(asset.distanceForMovement > 0)
            {
                asset.distanceForMovement -= asset.movingDistancePerTick;
                asset.currentPosition = calculateDestination(asset.coordinates, asset.distanceForMovement, asset.bearingForMovement)
            }
            else
            {
                asset.reachedEndPosition = true
                if(asset.loopUntilEndPosition) {
                    asset.blocked = true
                }
                
                hero.assets2Unblock.append(asset)
                end2Pd = "\(intPatcherTag)-end"
                PdBase.sendBang(toReceiver: end2Pd)
            }
        }
        
        if( (hero.timeInCurrentState * 1000 > (Double(asset.duration) + Double(asset.offset))) && !asset.loop && !asset.blocked && Int(asset.type) != RWAASSETTYPE_PD)
        {
            asset.blocked = true
            hero.assets2Unblock.append(asset)
            end2Pd = "\(intPatcherTag)-end"
            PdBase.sendBang(toReceiver: end2Pd)
        }
        
        if(asset.autoRotate) {
            asset.currentRotateAngleOffset += asset.rotateOffsetPerTick
        }
        
        // playhead tracking
        if(asset.updatePlayheadPosition)
        {
            // playheadPositionWithoutOffset is tracked in ms
            asset.playheadPositionWithoutOffset += Double(schedulerRate) // 10 ms
            if(asset.playheadPositionWithoutOffset >= Double(asset.offset)) {
                asset.playheadPosition += Double(schedulerRate)  * sampleRate // 10 * 48 = 480 samples per scheduler tick
            }
            
            // if asset reached fadeOutAfter:
            // - loop: reset playheadPosition
            // - oneshot: stop tracking playheadPosition
            // (playheadPosition is tracked in samples)
            if(asset.playheadPosition >= asset.fadeOutAfter * sampleRate)
            {
                asset.playheadPosition = 0;
                if(asset.loop == false) {
                    asset.updatePlayheadPosition = false
                }
            }
        }
    }
    
    func sendData2ActiveAssets()
    {
        // at the beginning of a game, this evaluates to FALLBACK state
        if(hero.currentState == nil) {
            return
        }

        // Instruments interval per game-tick Pd flush: every PdBase.send in
        // here takes libpd's sys_lock, which the render callback holds for a
        // whole audio buffer. Contention shows up as long intervals here.
        let spid = OSSignpostID(log: headtrackingSignpostLog)
        os_signpost(.begin, log: headtrackingSignpostLog, name: "pd_flush", signpostID: spid)
        defer { os_signpost(.end, log: headtrackingSignpostLog, name: "pd_flush", signpostID: spid) }

        if(!hero.activeAssets.isEmpty) {
            for mapItem in hero.activeAssets
            {
                sendData2Asset(mapItem: mapItem.value);
            }
            step = 0;
        }

        if(!hero.backgroundAssets.isEmpty) {
            for mapItem in hero.backgroundAssets
            {
                sendData2Asset(mapItem: mapItem.value);
            }
            step = 0;
        }
    }
    
    // The gain that actually reaches Pd: asset gain * state gain * scene gain.
    // Creator sends this every tick, we only need it at activation since
    // nothing edits gain while a game runs.
    func effectiveGain(_ asset: RwaAsset, _ state: RwaState?, _ scene: RwaScene?) -> Double
    {
        var gain = asset.gain
        if let state = state {
            gain *= state.gain
        }
        if let scene = scene {
            gain *= scene.gain
        }
        return gain
    }

    func sendInitValues2Pd(_ asset:RwaAsset, _ patcherTag: Int, gain: Double)
    {
        var pdReceiver: String
        
        if(asset.moveFromStartPosition)
        {
            asset.currentPosition = asset.startPosition
            asset.reachedEndPosition = false
        }
        else
        {
            asset.currentPosition = asset.coordinates
            asset.reachedEndPosition = true
        }
        
        var firstCrossfadeAfter = asset.fadeOutAfter;
        asset.playheadPositionWithoutOffset = 0
        asset.updatePlayheadPosition = true;
        
        if(asset.alwaysPlayFromBeginning == true) {
            asset.playheadPosition = 0;
        }
        else
        {
            firstCrossfadeAfter -= (asset.playheadPosition/sampleRate)
            if(firstCrossfadeAfter < 0)
            {
                firstCrossfadeAfter = asset.fadeOutAfter
                asset.playheadPosition = 0
            }
        }
        
        asset.distanceForMovement = calculateDistance(asset.startPosition, p2: asset.coordinates) * 1000
        asset.movingDistancePerTick = Double(asset.movementSpeed) * Double(schedulerRate)/1000.0
        asset.rotateOffsetPerTick = Float(Double(asset.rotateFrequency) * 360.0 * Double(schedulerRate)/1000.0)
        asset.currentRotateAngleOffset = 0

        // shouldn't this be asset.currentPosition? so that moving assets start  in the right place? (see RWA Creator comments)
        pdReceiver = "\(patcherTag)-assetlon"
        PdBase.send(Double(asset.coordinates.longitude), toReceiver: pdReceiver)

        pdReceiver = "\(patcherTag)-assetlat"
        PdBase.send(Double(asset.coordinates.latitude), toReceiver: pdReceiver)

        // .ogg player needs samplerate
        pdReceiver = "\(patcherTag)-samplerate"
        PdBase.send((Double(sampleRate * 1000)), toReceiver: pdReceiver)

        // how many azimuthN/distanceN/elevationN channels this asset will be
        // streamed, so patches can adapt (derived from the playback mode; the
        // channelcount XML attribute is unreliable and not used)
        pdReceiver = "\(patcherTag)-numchannels"
        PdBase.send(Double(asset.playbackChannelCount()), toReceiver: pdReceiver)
        
        pdReceiver = "\(patcherTag)-dampingfunction"
        PdBase.send((Double(asset.dampingFunction)), toReceiver: pdReceiver)
        
        pdReceiver = "\(patcherTag)-dampingfactor"
        PdBase.send(Double(asset.dampingFactor), toReceiver: pdReceiver)
        
        pdReceiver = "\(patcherTag)-dampingtrim"
        PdBase.send(Double(asset.dampingTrim), toReceiver: pdReceiver)
        
        pdReceiver = "\(patcherTag)-dampingmin"
        PdBase.send(Double(asset.dampingMin), toReceiver: pdReceiver)
        
        pdReceiver = "\(patcherTag)-dampingmax"
        PdBase.send(Double(asset.dampingMax), toReceiver: pdReceiver)
        
        pdReceiver = "\(patcherTag)-smoothdist"
        PdBase.send(Double(asset.smoothDistance), toReceiver: pdReceiver)
        
        pdReceiver = "\(patcherTag)-offset"
        PdBase.send(Double(asset.offset), toReceiver: pdReceiver)
        
        pdReceiver = "\(patcherTag)-loop"
        PdBase.send(boolean2Double(asset.loop), toReceiver: pdReceiver)
        
        // effective gain (scene x state x asset), see effectiveGain(); also in RWA Creator
        pdReceiver = "\(patcherTag)-gain"
        PdBase.send(gain, toReceiver: pdReceiver)
        
        pdReceiver = "\(patcherTag)-fadeintime"
        PdBase.send(Double(asset.fadeInTime), toReceiver: pdReceiver)
        
        pdReceiver = "\(patcherTag)-fadeouttime"
        PdBase.send(Double(asset.fadeOutTime), toReceiver: pdReceiver)
        
        pdReceiver = "\(patcherTag)-crossfadetime"
        PdBase.send(Double(asset.crossfadeTime), toReceiver: pdReceiver)
        
        pdReceiver = "\(patcherTag)-crossfadeafter"
        PdBase.send(Double(asset.fadeOutAfter), toReceiver: pdReceiver)
        
        pdReceiver = "\(patcherTag)-firstcrossfade"
        PdBase.send(Double(firstCrossfadeAfter), toReceiver: pdReceiver)

        pdReceiver = "\(patcherTag)-playheadposition"
        PdBase.send((Double(asset.playheadPosition)), toReceiver: pdReceiver)

        // fresh seed per activation for [random] etc. in Pd asset patches
        pdReceiver = "\(patcherTag)-seed"
        PdBase.send(Double(1 + (seedSource() & 0xFFFFFE)), toReceiver: pdReceiver)

        pdReceiver = "\(patcherTag)-play"
        let path = fullAssetPath + "/" + asset.name
        PdBase.sendSymbol(path , toReceiver: pdReceiver)
        
        self.logger.debug("Initialised asset: \(asset.name) sent to patcher id \(patcherTag), gain: \(asset.gain)")
    }
    
    func startBackgroundState()
    {
        var state: RwaState
        var patcherTag: Int32
        
        state = hero.currentScene!.backgroundState
        
        self.logger.info("Starting Background State of \(hero.currentScene!.name)");
        
        if(state.stateName == "") {
            return }
        if(state.assets.isEmpty) {
            return }
        
        for asset in state.assets
        {
            // An instance from an earlier visit may still be fading out (scene re-entered
            // within the fade-out window). Park its patcher for release on its
            // "-playfinished" before the new instance takes over the map slot.
            // Mirror of RwaRuntime::startBackgroundState in the Creator.
            if let fading = hero.backgroundAssets.removeValue(forKey: asset.uniqueId) {
                assetsPendingRelease.append(fading)
            }

            patcherTag = findFreePatcher(asset: asset)
            sendInitValues2Pd(asset, Int(patcherTag), gain: effectiveGain(asset, state, hero.currentScene)) // sends "-gain" itself
            let mapItem: RwaEntity.AssetMapItem = RwaEntity.AssetMapItem(asset, patcherTag)
            hero.backgroundAssets[asset.uniqueId] = mapItem
            self.logger.info("Add Background Asset '\(asset.name)'")
        }
    }
    
    func resetGame()
    {
        hero.timeInCurrentScene = 0;
        hero.timeInCurrentState = 0;

        for item in assetsPendingRelease {
            releasePatcherFromItem(item)
        }
        assetsPendingRelease.removeAll()

        if(!scenes.isEmpty)
        {
            for scene in scenes
            {
                for state in scene.states {
                    state.blockUntilRadiusHasBeenLeft = false
                    
                    for asset in state.assets {
                        asset.playheadPosition = 0
                        asset.playheadPositionWithoutOffset = 0
                        asset.updatePlayheadPosition = true;
                        asset.blockedForever = false;
                        asset.blocked = false;
                    }
                }
            }
        }
    }
    
    func startGame()
    {
        resetGame()
        
        if(!scenes.isEmpty)
        {
            setScene(scene: scenes[0])
        }
    }
    
    func processAssets()
    {
        if(hero.currentState == nil) {
            return }
        if(hero.currentState?.assets.isEmpty)! {
            return }

        for asset in (hero.currentState?.assets)!
        {
            if(!hero.isActiveAsset(asset.uniqueId) && !asset.blocked && !asset.mute && !asset.blockedForever)
            {
                let patcherTag = findFreePatcher(asset: asset)
                sendInitValues2Pd(asset, Int(patcherTag), gain: effectiveGain(asset, hero.currentState, hero.currentScene))

                if(asset.playOnce) {
                    asset.blockedForever = true;
                }

                hero.activeAssets[asset.uniqueId] = RwaEntity.AssetMapItem(asset, patcherTag)

                self.logger.info("Add active asset for state '\(hero.currentState!.stateName)': \(asset.name)")

                break
            }
        }
    }
    
    // SecondViewController.timer (10ms) -> SecondViewController.countUp() RwaGameLoop.updateGameState() -> RwaGameLoop.processAssets()
    func updateGameState()
    {
        sendData2ActiveAssets()
        setEntityState()
        processAssets()
        
        hero.timeSinceLastGpsUpdate += Double(schedulerRate)
        if(!headTrackerConnected) {
            hero.disconnectedFromHeadtrackerSince += Double(schedulerRate)
        }
        
        if(hero.timeSinceLastGpsUpdate > 20000) {
            //print("Please Return, Gps seems broken")
        }
        
        if(hero.disconnectedFromHeadtrackerSince > 20000) {
            //print("Please Return, headtracker seems broken")
        }
    }
 
    func receiveBang(fromSource source: String!)
    {
        let parts = source.components(separatedBy: "-")
        var patcherTag: Int
        var gain2Pd: String
        
        if(parts.last == "playfinished")
        {
            patcherTag = Int(parts.first!)!
            for mapItem in hero.activeAssets
            {
                if(mapItem.value.patcherTag == Int32(patcherTag) )
                {
                    gain2Pd = "\(patcherTag)-gain"
                    PdBase.send(Double(0.0), toReceiver: gain2Pd)
                    hero.removeActiveAsset(Int32(patcherTag))
                    
                    self.logger.info("Release patcher \(patcherTag) of asset \(mapItem.value.asset.name)")
                    
                    releasePatcherFromItem(mapItem.value)
                }
            }
            
            for mapItem in hero.backgroundAssets
            {
                if(mapItem.value.patcherTag == Int32(patcherTag) )
                {
                    gain2Pd = "\(patcherTag)-gain"
                    PdBase.send(Double(0.0), toReceiver: gain2Pd)
                    hero.removeBackgroundAsset(Int32(patcherTag))
                    
                    self.logger.info("Release patcher \(patcherTag) of background-asset \(mapItem.value.asset.name)")
                    
                    releasePatcherFromItem(mapItem.value)
                    
                }
            }

            // superseded background instance finished its fade-out
            assetsPendingRelease.removeAll { item in
                if item.patcherTag == Int32(patcherTag) {
                    releasePatcherFromItem(item)
                    self.logger.info("Released superseded background patcher \(patcherTag)")
                    return true
                }
                return false
            }
        }
        
        if(parts.last == "back2ios") {
            self.logger.debug("PD, bang")
        }
    }
    
    func receive(_ received: Float, fromSource source: String!) {
        
        if(source == "back2ios") {
            self.logger.debug("PD, from back2ios: \(received)")
        }
        
        if(source == "back2ios1") {
            self.logger.debug("PD, from back2ios1: \(received)")
        }
        
        if(source == "back2ios2") {
            self.logger.debug("PD, from back2ios2: \(received)")
        }
    }
    
    func receiveMessage(_ message: String!, withArguments arguments: [AnyObject]!, fromSource source: String!) {
        
        for i in 0 ..< arguments.count {
            self.logger.debug("PD, message: \(String(describing: arguments[i]))")
        }
    }
    
    func receiveSymbol(_ symbol: String!, fromSource source: String!)
    {
        self.logger.debug("PD, symbol: \(symbol ?? "<empty>"))")
    }
}
