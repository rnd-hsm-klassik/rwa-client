//
//  FirstViewController.swift
//  rwa client
//
//  Created by Thomas Resch on 28/12/15.
//  Copyright © 2015 beryllium design. All rights reserved.
//

import UIKit

var hero:RwaEntity = RwaEntity(name: "me")
var compassAzimuth:Float = Float()
var currentGame:String = ""
var downloadManager = DownloadManager.shared
var documentsDirectory = FileManager.default.urls(for:.documentDirectory, in: .userDomainMask)[0]
var games2Download = [String]()
var gameIsInDocumentsFolder:Bool = Bool();
var fullGamePath:String = String();
var fullAssetPath:String = String();
var defaultGame:String = String();

class FirstViewController: UIViewController, UITableViewDelegate, UITableViewDataSource, PdListener {

    @IBOutlet var gameTable:UITableView!

    var rwaimport:RwaImport = RwaImport()
    var games:GameManager = GameManager()
    let loadingSpinner = UIActivityIndicatorView(activityIndicatorStyle: .whiteLarge)
    // The default game loads once per app run, deferred to the first
    // didBecomeActive so launch (view setup, audio-session activation)
    // finishes before the heavy load/connect automation starts.
    var didAutoLoadDefaultGame = false
    
    func emptyDocumentsDirectory()
    {
        do {
            let fileURLs = try FileManager.default.contentsOfDirectory(at: documentsDirectory, includingPropertiesForKeys: nil, options: .skipsHiddenFiles)
            for fileURL in fileURLs {
                try FileManager.default.removeItem(at: fileURL)
                logger.debug("removing \(fileURL.lastPathComponent)")
            }
        } catch  {
            logger.error("Failed to empty the documents directory: \(error)")
        }
    }
    
    func createDirectoryInDocuments(dirName:String)
    {
        let documentsURL = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first

        if let documentsURL = documentsURL
        {
            let destURL = documentsURL.appendingPathComponent("assets")
            FileManager.createDirectory(myDir: destURL)
            logger.debug("created directory: \(destURL.relativePath)")
        }
    }
    
    func copyRwaGamesFromBundleToDocumentsFolder()
    {
        if let resPath = Bundle.main.resourcePath {
            do
            {
                let dirContents = try FileManager.default.contentsOfDirectory(atPath: resPath)
                let filteredFiles = dirContents.filter{ $0.contains(".rwa")}
                if let documentsURL = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first
                {
                    for fileName in filteredFiles {
                        
                        let sourceURL = Bundle.main.bundleURL.appendingPathComponent(fileName)
                        let destURL = documentsURL.appendingPathComponent(fileName)
                        do {
                            FileManager.default.secureCopyItem(at: sourceURL, to: destURL)
                        }
                    }
                }
            } catch { }
        }
    }
    
    func copyRwaAssetsFromBundleToDocumentsFolder()
    {
        if let resPath = Bundle.main.resourcePath {
            do
            {
                let dirContents = try FileManager.default.contentsOfDirectory(atPath: resPath)
                var filteredFiles = dirContents.filter{ $0.contains(".aif")}
                filteredFiles += dirContents.filter{ $0.contains(".wav")}
                filteredFiles += dirContents.filter{ $0.contains(".pd")}
                filteredFiles += dirContents.filter{ $0.contains(".ogg")}
                
                if let documentsURL = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first
                {
                    for fileName in filteredFiles {
                        
                        let sourceURL = Bundle.main.bundleURL.appendingPathComponent(fileName)
                        let destURL = documentsURL.appendingPathComponent("assets").appendingPathComponent(fileName)
                        do {
                            FileManager.default.secureCopyItem(at: sourceURL, to: destURL)
                        }
                    }
                }
            } catch { }
        }
    }
    
    @ objc func nameOfFunction(notif: NSNotification) {
        
        for game in games2Download
        {
            let remoteUrl = URL(string: "http://"+rwaCreatorIP+":8088/" + game)!
            downloadManager.startDownload(url: remoteUrl)
        }
    }
    
    @ objc func updateGamesList(notif: NSNotification) {
        print("Recievied updte Gamelist")
        games.populateGames()
        
        DispatchQueue.main.async {
            self.gameTable.reloadData()
        }
    }
    
    // Wired to the "Fetch Games" bar button on the Games tab; the Creator IP
    // (rwaCreatorIP) is set on the Settings tab.
    @IBAction func fetchGames(_ sender: Any)
    {
        let alert = UIAlertController(title: "Fetch Games", message: "This will delete existing games on the device, are you sure?", preferredStyle: .alert)

        alert.addAction(UIAlertAction(title: NSLocalizedString("OK", comment: "Default action"), style: .default, handler: { _ in
            self.emptyDocumentsDirectory();
            logger.info("Received update Games")
            self.games.clear()
            let remoteURL = URL(string: "http://"+rwaCreatorIP+":8088/allfiles.txt")!
            downloadManager.startDownload(url: remoteURL)
        }))
        
        alert.addAction(UIAlertAction(title: NSLocalizedString("Cancel", comment: "Abort"), style: .default, handler: { _ in
            logger.info("Aborted")
        }))

        self.present(alert, animated: true, completion: nil)
    }
    
    /// Loads a game without blocking the UI: a running game is stopped
    /// first (the 10 ms tick must not read `scenes` mid-parse), the XML
    /// parse runs on a background queue (pure Foundation), and the Pd
    /// patcher work stays on the main thread — libpd calls are only ever
    /// issued from there. The spinner over the games list animates during
    /// the parse; `completion` runs on main after "Game Loaded" is posted.
    ///
    /// The stop is two-phase and asynchronous (master fade, then silent
    /// teardown), so the load is queued on "Game Stopped": parsing must not
    /// race the fading run, and initDynamicPatchers() must not close
    /// patchers that are still completing their release protocol.
    func loadGameAndInitDynamicPatchers(game: String, completion: (() -> Void)? = nil) {
        loadingSpinner.startAnimating()
        gameTable.isUserInteractionEnabled = false

        // Hop through the runloop once so the spinner actually renders:
        // merely touching `rwagameloop` below materializes the lazy global,
        // which opens the ~170 static patchers synchronously on first use.
        DispatchQueue.main.async {
            let proceed = {
                DispatchQueue.global(qos: .userInitiated).async {
                    self.rwaimport.readRwa(game)

                    DispatchQueue.main.async {
                        rwagameloop.initDynamicPatchers()
                        self.loadingSpinner.stopAnimating()
                        self.gameTable.isUserInteractionEnabled = true
                        NotificationCenter.default.post(name: NSNotification.Name(rawValue: "Game Loaded"), object: nil)
                        completion?()
                    }
                }
            }

            if rwagameloop.isRunning {
                var observer: NSObjectProtocol?
                observer = NotificationCenter.default.addObserver(forName: NSNotification.Name(rawValue: "Game Stopped"),
                                                                  object: nil, queue: OperationQueue.main) { _ in
                    if let observer = observer {
                        NotificationCenter.default.removeObserver(observer)
                    }
                    proceed()
                }
                NotificationCenter.default.post(name: NSNotification.Name(rawValue: "Stop Game"), object: nil)
            }
            else {
                proceed()
            }
        }
    }
    
    /// The storyboard hardcodes literal white for this scene's view and
    /// table (and 80% alpha on the table, which only ever muddied it against
    /// that white). Static colors do not follow light/dark, so the area
    /// behind the navigation bar and tab bar stayed white in dark mode.
    /// Swapped for adaptive system colors in code — the storyboard is
    /// legacy scaffolding we do not edit (see CLAUDE.md).
    private func applyAdaptiveColors() {
        view.backgroundColor = .systemBackground
        gameTable.backgroundColor = .systemBackground
        gameTable.alpha = 1.0
        // The storyboard's "Default Game" caption (no outlet, only label
        // directly in this view) is obsolete since the default-game switch
        // moved to Settings. Hide it.
        for label in view.subviews.compactMap({ $0 as? UILabel }) {
            label.isHidden = true
        }
    }

    override func viewDidLoad()
    {
        super.viewDidLoad()

        applyAdaptiveColors()

        NotificationCenter.default.addObserver(self, selector: #selector(self.nameOfFunction), name: NSNotification.Name(rawValue: "receivedGameList"), object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(self.updateGamesList), name: NSNotification.Name(rawValue: "receivedGame"), object: nil)
        
        createDirectoryInDocuments(dirName: "assets")
        copyRwaGamesFromBundleToDocumentsFolder();
        copyRwaAssetsFromBundleToDocumentsFolder();
        self.games.populateGames()
        self.gameTable.reloadData()
        
        hero.coordinates.latitude = 47.5546492;
        hero.coordinates.longitude = 7.5594406;

        loadingSpinner.hidesWhenStopped = true
        loadingSpinner.color = .label
        loadingSpinner.center = view.center
        loadingSpinner.autoresizingMask = [.flexibleTopMargin, .flexibleBottomMargin,
                                           .flexibleLeftMargin, .flexibleRightMargin]
        view.addSubview(loadingSpinner)

        NotificationCenter.default.addObserver(self, selector: #selector(self.autoLoadDefaultGame),
                                               name: NSNotification.Name.UIApplicationDidBecomeActive,
                                               object: nil)
    }

    @objc func autoLoadDefaultGame() {
        if didAutoLoadDefaultGame || defaultGame == "" {
            return
        }
        didAutoLoadDefaultGame = true
        logger.debug("Default game: \(defaultGame)")

        // Stored Documents-relative; resolve against the *current*
        // container. Legacy installs stored the absolute path, whose
        // container UUID changes on every app update — strip it down to
        // the relative part and migrate the stored value.
        var relativeGame = defaultGame
        if relativeGame.hasPrefix("/"),
           let range = relativeGame.range(of: "/Documents/") {
            relativeGame = String(relativeGame[range.upperBound...])
        }
        let documentsPath = FileManager.default.urls(for: .documentDirectory,
                                                     in: .userDomainMask)[0].relativePath
        let gamePath = documentsPath + "/" + relativeGame

        if FileManager.default.fileExists(atPath: gamePath) {
            if relativeGame != defaultGame {
                defaultGame = relativeGame
                UserDefaults.standard.set(relativeGame, forKey: defaultsKeys.defaultGame)
                logger.info("Migrated default game to Documents-relative path: \(relativeGame)")
            }
            let dir = (gamePath as NSString).deletingLastPathComponent
            fullAssetPath = dir + "/" + "assets"
            currentGame = gamePath
            loadGameAndInitDynamicPatchers(game: gamePath) { [weak self] in
                self?.tabBarController?.selectedIndex = 1
            }
        }
        else {
            // Stay on the Games list instead of showing a phantom title
            // over an empty scene list ("Start does nothing").
            logger.error("Default game not found, skipping auto-load: \(gamePath)")
        }
    }
    
    override func viewWillAppear(_ animated: Bool)
    {
        gameTable.reloadData()
    }

    override func didReceiveMemoryWarning()
    {
        super.didReceiveMemoryWarning()
        // Dispose of any resources that can be recreated.
    }
    
    func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int
    {
        return games.rwaGames.count
    }

    // The "set default game" switch moved to Settings > Soundwalk >
    // Default game; the list is selection-only now. A checkmark
    // marks the current default game.
    func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell
    {
        let cell: UITableViewCell = UITableViewCell(style: UITableViewCellStyle.subtitle, reuseIdentifier: "Default")
        cell.textLabel!.text = games.rwaGames[indexPath.row].name
        // Kept populated but hidden: the second line is reserved for game
        // metadata later; the absolute Documents path it holds today is
        // operator noise (and selection reads the model, not this label).
        cell.detailTextLabel!.text = games.rwaGames[indexPath.row].path
        cell.detailTextLabel!.isHidden = true
        cell.accessoryType = (defaultGame == games.rwaGames[indexPath.row].name)
            ? .checkmark : .none
        return cell;
    }

    func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath)
    {
        // Read from the model, not the cell labels. The detail label is
        // hidden today and will carry metadata later.
        let game = games.rwaGames[indexPath.row]
        currentGame = game.name

        let comps = currentGame.components(separatedBy: "/")
        if(comps.count > 1) {
            fullAssetPath = game.path + "/" + comps[0] + "/assets"
        }
        else {
            fullAssetPath = game.path + "/" + "assets"
            gameIsInDocumentsFolder = true;
        }

        fullGamePath = game.path + "/" + currentGame

        logger.info("loading game: \(fullGamePath)")
        logger.info("loading assets folder: \(fullAssetPath)")

        loadGameAndInitDynamicPatchers(game: fullGamePath) { [weak self] in
            self?.tabBarController?.selectedIndex = 1
        }
    }
}
