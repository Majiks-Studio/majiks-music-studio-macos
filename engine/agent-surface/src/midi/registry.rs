use std::{collections::HashMap, fs, path::{Path, PathBuf}};
use serde_json::{json, Value};
use super::map::{match_specificity, validate_map, DeviceMatch, MidiMap};

const BUNDLED: &[(&str, &str)] = &[("sx-kc211", include_str!("../../assets/midi-maps/sx-kc211.json")), ("generic-controller", include_str!("../../assets/midi-maps/generic-controller.json"))];

/// The subsystem settings file name beside `midi-maps/` (spec 4).
const SETTINGS_FILE: &str = "midi-settings.json";

#[derive(Debug, Clone)] pub struct LoadedMap { pub key: String, pub map: MidiMap, pub source: String, pub error: Option<String> }
/// What a port's KEYS do. See `midi.port.role.set` in the catalog.
///
/// The DEFAULT is `Instrument`, and that is the whole point: a musician who
/// plugs in a keyboard expects the keys to play notes. Before this existed,
/// every note a bundled map bound (on the SX-KC211 that is C2..D4 — over two
/// octaves including middle C) fired transport/undo/Sterling instead, so the
/// moment an instrument became audible, playing middle C would have triggered
/// "add a layer". Roles fix that without deleting anyone's bindings: flip the
/// port to `Control` and every binding is back.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Default)]
pub enum PortRole {
    /// Notes play the selected instrument track. Note-matched control bindings
    /// are suppressed; CC / pitch-bend bindings still fire, so a controller
    /// with knobs keeps them.
    #[default]
    Instrument,
    /// Every binding fires, including note-matched ones. Notes never sound.
    Control,
}

impl PortRole {
    pub fn as_str(self) -> &'static str {
        match self {
            PortRole::Instrument => "instrument",
            PortRole::Control => "control",
        }
    }

    pub fn parse(s: &str) -> Option<Self> {
        match s {
            "instrument" => Some(PortRole::Instrument),
            "control" => Some(PortRole::Control),
            _ => None,
        }
    }
}

#[derive(Debug, Clone, Default)] pub struct MapRegistry { pub maps: HashMap<String, LoadedMap>, pub overrides: HashMap<String, String>, pub roles: HashMap<String, PortRole>, pub dir: Option<PathBuf> }

impl MapRegistry {
    pub fn bundled() -> Self { let mut r=Self::default(); for (k,s) in BUNDLED { if let Ok(m)=serde_json::from_str(s) { r.maps.insert((*k).into(),LoadedMap{key:(*k).into(),map:m,source:"bundled".into(),error:None}); } } r }

    /// The `<key>.json` body of a bundled map, for verbatim export.
    pub fn bundled_body(key: &str) -> Option<&'static str> { BUNDLED.iter().find(|(k,_)| *k==key).map(|(_,s)| *s) }
    pub fn is_bundled_key(key: &str) -> bool { BUNDLED.iter().any(|(k,_)| *k==key) }

    pub fn install(dir: &Path) -> Result<(), String> { let d=dir.join("midi-maps"); fs::create_dir_all(&d).map_err(|e|e.to_string())?; for (k,s) in BUNDLED { let p=d.join(format!("{k}.json")); if !p.exists() { fs::write(p,s).map_err(|e|e.to_string())?; } } Ok(()) }

    pub fn maps_dir(&self) -> Option<PathBuf> { self.dir.as_ref().map(|d| d.join("midi-maps")) }
    pub fn settings_path(&self) -> Option<PathBuf> { self.dir.as_ref().map(|d| d.join(SETTINGS_FILE)) }

    pub fn load(dir: Option<PathBuf>) -> Self {
        let mut r=Self{dir:dir.clone(),..Self::bundled()};
        if let Some(d)=dir {
            let _=Self::install(&d);
            if let Ok(es)=fs::read_dir(d.join("midi-maps")) {
                for e in es.flatten().filter(|e|e.path().extension().and_then(|x|x.to_str())==Some("json")) {
                    if let Ok(text)=fs::read_to_string(e.path()) {
                        let key=e.path().file_stem().unwrap().to_string_lossy().into_owned();
                        // Installed bundled copies keep the "bundled" source; only
                        // non-bundled files on disk are user maps (spec source field).
                        let source = if Self::is_bundled_key(&key) { "bundled" } else { "user" };
                        match serde_json::from_str::<MidiMap>(&text) {
                            Ok(m) => match validate_map(&m) {
                                Ok(())=>{r.maps.insert(key.clone(),LoadedMap{key,map:m,source:source.into(),error:None});},
                                Err(x)=>r.invalid(key,source,x),
                            },
                            Err(x)=>r.invalid(key,source,x.to_string()),
                        }
                    }
                }
            }
            r.load_overrides();
        }
        r
    }

    /// Re-read maps + overrides from disk, keeping the same data dir.
    pub fn reload(&mut self) { *self = Self::load(self.dir.clone()); }

    fn invalid(&mut self, key:String, source:&str, error:String) { self.maps.insert(key.clone(),LoadedMap{key:key.clone(),map:MidiMap{version:1,name:key,device:DeviceMatch{name_patterns:vec![]},author:None,tested:false,source_url:None,unsupported_reason:None,bindings:vec![]},source:source.into(),error:Some(error)}); }

    fn load_overrides(&mut self) {
        let Some(p)=self.settings_path() else { return };
        let Ok(text)=fs::read_to_string(p) else { return };
        let Ok(v)=serde_json::from_str::<Value>(&text) else { return };
        if let Some(obj)=v.get("overrides").and_then(Value::as_object) {
            for (k,val) in obj { if let Some(s)=val.as_str() { self.overrides.insert(k.clone(), s.to_string()); } }
        }
        // Roles are stored ONLY when they differ from the default, so an
        // existing settings file with no `portRoles` key reads as "every port
        // is an instrument" — which is the intended default, not a migration.
        if let Some(obj)=v.get("portRoles").and_then(Value::as_object) {
            for (k,val) in obj {
                if let Some(role)=val.as_str().and_then(PortRole::parse) { self.roles.insert(k.clone(), role); }
            }
        }
    }

    /// Persist the current overrides + port roles to `midi-settings.json`.
    /// No-op in memory.
    pub fn save_overrides(&self) -> Result<(), String> {
        let Some(p)=self.settings_path() else { return Ok(()) };
        if let Some(parent)=p.parent() { fs::create_dir_all(parent).map_err(|e|e.to_string())?; }
        let roles: std::collections::BTreeMap<&String, &str> =
            self.roles.iter().map(|(k,v)| (k, v.as_str())).collect();
        let body=json!({
            "overrides": self.overrides.iter().collect::<std::collections::BTreeMap<_,_>>(),
            "portRoles": roles,
        });
        fs::write(p, serde_json::to_string_pretty(&body).unwrap_or_default()).map_err(|e|e.to_string())
    }

    /// The role for `port`. Unset = [`PortRole::Instrument`].
    pub fn role(&self, port: &str) -> PortRole {
        self.roles.get(port).copied().unwrap_or_default()
    }

    pub fn set_role(&mut self, port: &str, role: PortRole) {
        self.roles.insert(port.to_string(), role);
    }

    /// "auto" clears the override; anything else pins it (a map key or "none").
    pub fn set_override(&mut self, port: &str, value: &str) {
        if value=="auto" { self.overrides.remove(port); } else { self.overrides.insert(port.to_string(), value.to_string()); }
    }

    /// Resolve a map by its file-stem KEY or its display NAME (spec 5.1).
    pub fn find(&self, key_or_name: &str) -> Option<&LoadedMap> {
        self.maps.get(key_or_name).or_else(|| self.maps.values().find(|m| m.map.name==key_or_name))
    }

    /// Write a user map file `<stem>.json` and return its path. In memory: err.
    pub fn write_map_file(&self, stem: &str, map: &MidiMap) -> Result<PathBuf, String> {
        let d=self.maps_dir().ok_or_else(|| "no data dir; maps cannot be written in memory".to_string())?;
        fs::create_dir_all(&d).map_err(|e|e.to_string())?;
        let p=d.join(format!("{stem}.json"));
        fs::write(&p, serde_json::to_string_pretty(map).map_err(|e|e.to_string())?).map_err(|e|e.to_string())?;
        Ok(p)
    }

    pub fn resolve(&self, port: &str) -> Option<&LoadedMap> {
        if let Some(k)=self.overrides.get(port) {
            if k=="none" { return None }
            if let Some(m)=self.maps.get(k) { if m.error.is_none() && m.map.unsupported_reason.is_none() { return Some(m) } }
            // Dangling override (map removed or invalid): fall through to auto-detect.
        }
        self.maps.values()
            .filter(|m| m.error.is_none() && m.map.unsupported_reason.is_none())
            .filter(|m| match_specificity(&m.map, port) > 0)
            // Longest pattern wins; on a tie a user map beats a bundled one (spec 1.1).
            .max_by_key(|m| (match_specificity(&m.map, port), (m.source=="user") as u8))
    }

    /// The reason a pattern-matching map declines to load, for the port row.
    pub fn unsupported_reason_for(&self, port: &str) -> Option<String> {
        self.maps.values()
            .filter(|m| m.map.unsupported_reason.is_some() && match_specificity(&m.map, port) > 0)
            .max_by_key(|m| match_specificity(&m.map, port))
            .and_then(|m| m.map.unsupported_reason.clone())
    }

    pub fn json(&self) -> Value { json!(self.maps.values().map(|m|json!({"key":m.key,"name":m.map.name,"source":m.source,"tested":m.map.tested,"bindingCount":m.map.bindings.len(),"loadError":m.error})).collect::<Vec<_>>()) }
}
