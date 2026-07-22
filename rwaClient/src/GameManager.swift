//
//  GameManager.swift
//  rwa client
//
//  Created by Admin on 28/12/15.
//  Copyright © 2015 beryllium design. All rights reserved.
//

import UIKit
//import Zip

var gameMgr: GameManager = GameManager();

struct rwagame
{
    var name = "default"
    var path = "default"
}

class GameManager: NSObject
{
    var rwaGames = [rwagame]()
    var gamesPath:String = Bundle.main.resourcePath!
    var destUrl:URL = Bundle.main.resourceURL!;
    
    func addGame(_ name:String, path:String)
    {
        rwaGames.append(rwagame(name:name, path:path))
        print("APPEND GAME, COUNT IS \(rwaGames.count)")
    }
    
    func clear()
    {
        rwaGames = [rwagame]()
    }
     
    func populateGames()
    {
        clear() // rebuild from disk; callers may invoke this repeatedly
        let fileManager = FileManager.default
        let docuURLS = try! FileManager.default.contentsOfDirectory(at: destUrl, includingPropertiesForKeys: nil)
        let documentsDirectory = FileManager.default.urls(for:.documentDirectory, in: .userDomainMask)[0]
        
        let enumerator:FileManager.DirectoryEnumerator = fileManager.enumerator(atPath: documentsDirectory.relativePath)!
        while let element = enumerator.nextObject() as? String
        {
            if element.hasSuffix("rwa")
            {
                print(element)
                addGame(element, path: documentsDirectory.relativePath)
            }
        }
    }
}
