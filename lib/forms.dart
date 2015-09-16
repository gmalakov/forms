library forms;

import 'package:yaml/yaml.dart' as yaml;
import 'package:mustache/mustache.dart' as mustache;

import 'dart:io';
import 'dart:async';
import 'dart:convert';

import 'package:path/path.dart' as pth;
import 'package:watcher/watcher.dart';


class FileMaps {
  static int maxMin = 20;
  DirectoryWatcher _watcher;

  String _fPath = "templates";
  Map<String,String> files = new Map();
  Map<String,DateTime> loaded = new Map();

  String get fPath => _fPath;
  set fPath(String val) {
    _fPath = val;
    initWatcher();
  }

  static Future<String> readFile(String fName) async {
    File f = new File(fName);
    if (await f.exists()) {
       String res = await f.openRead().transform(new Utf8Decoder(allowMalformed: true)).join();
       return res;
     } else return null;
  }

  Future<bool> _loadFile(String name) async {
    String res = await readFile(fPath+"/"+name);
    if (res == null) files[name] = fPath+"/"+name+" not found!";
     else files[name] = res;
    loaded[name] = new DateTime.now();
    return (res != null);
  }

  void clearOld() {
    if ((maxMin == null) || (maxMin == 0)) return;
    List<String> old = new List();

    //Calculate time difference from time loaded to now
    DateTime cDate = new DateTime.now();
    loaded.forEach((n,v) {
      if (v.difference(cDate).inMinutes > maxMin) old.add(n);
    });

    //Remove old entries
    old.forEach((n) {
      files.remove(n);
      loaded.remove(n);
    });
  }

  Future<String> getFile(String name) async {
   clearOld();
   if (files[name] == null) await _loadFile(name);
   return files[name];
  }

  String relPath(String absPath) {
    absPath = absPath.replaceAll("\\", "/");
    int idx = absPath.indexOf(fPath);
    if (idx > -1)
      try { absPath = absPath.substring(idx+fPath.length+1, absPath.length); } catch (err) { absPath = ""; }
    return absPath;
  }

  void initWatcher() {
    String absPth = pth.absolute(fPath).replaceAll("\\", "/");

    new Directory(fPath).exists().then((res) {
      if (res) {
        _watcher = new DirectoryWatcher(absPth);
        //print("Watching $absPth");

        if (_watcher != null) _watcher.events.listen((WatchEvent ev) {
          String rPath = relPath(ev.path);
          //print(rPath);
          switch (ev.type) {
            case ChangeType.MODIFY:
              if (files[rPath] != null) {
                files.remove(rPath); //remove old file
                loaded.remove(rPath); //remove old datetime
                _loadFile(rPath); //reload file
                //print("reloaded file: $rPath");
              }
              break;
            case ChangeType.REMOVE:
              files.remove(rPath); //remove old file
              loaded.remove(rPath); //remove old datetime
              break;
          }
        });
      } //else print(absPth+" does not exist!");
   });
  }


  FileMaps([String filePath]) {
    if (filePath != null) fPath = filePath;
  }


  //Create singleton object
  static FileMaps _fMaps = new FileMaps();
  static FileMaps get instance => _fMaps;

}

class DataMaps {
  //Functions in tools Map xxx(Map par)

  Map<String,Map> _data = new Map();
  Map<String, Function> _tools = new Map();
  Map<String,String> _param = new Map();

  static DataMaps _dMap = new DataMaps();
  static DataMaps get instance => _dMap;

  void setPar(String opt) {
    if ((opt == null) || (opt.length == 0)) return;
    _param.clear();

    List<String> sOpt = opt.split("&");
    sOpt.forEach((el) {
      List<String> sEl = el.split("=");
      //Trim elements
      sEl[0] = sEl[0].trim();
      sEl[1] = sEl[1].trim();

      //Create output parameter map
      if ((sEl[0] != "") && (sEl[1] != null) && (sEl[1] != "")) _param[sEl[0]] = sEl[1];
    });
 }

  set param(Map par) => (_param = par);

  Future<Map> getData(String name) {
    Completer completer = new Completer();
    if (name == null) {
      completer.complete( new Map());
      return completer.future;
    }

    //Get data from map
    Map rMap = _data[name];

    //If empty data try to collect from tools
    if (rMap == null) {
      //On empty map execute function linked // functions linked
      List<String> names = name.split(",");


      //Generate functions for Future Wait
      List funcs = new List();
      for(int i = 0; i < names.length; i++) {
        String cName = names[i].trim();
        if (_tools[cName] != null) funcs.add(_tools[cName](_param));
      }

      //Wait functions to complete
      Future.wait(funcs).then((List rList) {
         Map oMap = new Map();

         //Generate map for each functions results
         rList.forEach((Map el) {
           if (el != null)  oMap.addAll(el);
         });


         _data[name] = oMap;

         //Complete future when ready
         completer.complete(oMap);
      });

    } else { completer.complete(rMap); //If data[name] is not null and no future is needed
      //print("data is cached");
    }

    return completer.future;
  }

  void clearData() => (_data.clear());
  void clearFunc() {
    _tools.clear();
    _param.clear();
  }

  void putData(String name, Map data) {
    this._data[name] = data;
  }

  void setFunc(String name, Function regFunc) {
    _tools[name] = regFunc;
  }

}

class BasicRender {
  Map deps = null;
  String confName;

  BasicRender(this.confName);

  Future<bool> loadConf() async {
    String source = await FileMaps.instance.getFile(confName);
    try { deps = yaml.loadYaml(source) as Map; } catch (err) {
      deps = new Map(); return false;
    }
   return true;
  }

  Future<String> get render async {
     await loadConf();
     DataMaps.instance.clearData();
     return await _render("");
  }

  Future<String> _render(String path) async {
    //Trim first /
    if ((path.length > 0) && (path[0]== "/")) path = path.substring(1,path.length);

    List sPath = path.split("/");
    Map cDep  = deps;

    //Find current path in dependencies
    //print ("PATH:"+path);
    if ((path.length > 0) && (sPath.length > 0))
      sPath.forEach((el) => cDep=cDep[el]);

    String dBody = cDep["Body"];
    Map Data = await DataMaps.instance.getData(cDep["Data"]);
    Map Edit = await DataMaps.instance.getData(cDep["Edit"]);

      //Successfuly loaded map Edit -> merge Edit into Data
    if (Edit != null)
     Edit.forEach((n,v) => Data[n] = v);

      for (String n in cDep.keys) {
        //if parameter is different from Body or Data -
        //Create recursive render and set data into Data[parameter]

        if ((n != "Body") && (n != "Data") && (n != "Edit"))
          Data[n] = await _render(path+"/"+n);
      }

      //Read template file
       String source;
       source = await FileMaps.instance.getFile(dBody);


      //Render file
       String output;
       try {
         mustache.Template template = new mustache.Template(source,htmlEscapeValues:false);
         output = template.renderString(Data);
       }
       catch (err) {
          output = err.toString();
       }

       return output;
  }

}