use crate::session::{CoreEvent, CoreEventKind, ProtocolPeer, WireProtocol};
use anyhow::{anyhow, Context, Result};
use serde::{Deserialize, Serialize};
use serde_json::{json, Value};
use std::{collections::HashMap, sync::Arc, time::Duration};
use tokio::sync::{broadcast, Mutex};

#[derive(Clone, Debug, Serialize, Deserialize)]
pub struct DeviceInfo {
    pub id: String,
    pub name: String,
    pub platform: String,
    pub platform_type: Option<String>,
    pub emulator: bool,
    pub emulator_id: Option<String>,
}
#[derive(Clone, Debug, Serialize, Deserialize)]
pub struct EmulatorInfo {
    pub id: String,
    pub name: String,
    pub platform_type: Option<String>,
}

pub(crate) struct DeviceManager {
    peers: Mutex<HashMap<String, Arc<ProtocolPeer>>>,
    events: broadcast::Sender<CoreEvent>,
    pub(crate) removed: broadcast::Sender<(String, String)>,
}
impl DeviceManager {
    pub(crate) fn new(events: broadcast::Sender<CoreEvent>) -> Self {
        let (removed, _) = broadcast::channel(128);
        Self {
            peers: Mutex::new(HashMap::new()),
            events,
            removed,
        }
    }
    async fn peer(&self, sdk_path: &str) -> Result<Arc<ProtocolPeer>> {
        let sdk = crate::sdk::resolve_sdk(None, Some(sdk_path.into())).await?;
        let mut peers = self.peers.lock().await;
        if let Some(peer) = peers.get(&sdk.path) {
            if !peer.is_closed() {
                return Ok(peer.clone());
            }
        }
        if let Some(peer) = peers.remove(&sdk.path) {
            let _ = peer.terminate().await;
        }
        let peer = ProtocolPeer::spawn(
            &sdk,
            &["daemon".into()],
            None,
            &HashMap::new(),
            WireProtocol::Daemon,
            None,
            false,
        )?;
        let mut receiver = peer.events.subscribe();
        let events = self.events.clone();
        let removed = self.removed.clone();
        let path = sdk.path.clone();
        tokio::spawn(async move {
            let mut sequence = 0;
            loop {
                let event = match receiver.recv().await {
                    Ok(event) => event,
                    Err(broadcast::error::RecvError::Lagged(_)) => {
                        json!({"_fault":"Device event stream overflowed; refresh device list"})
                    }
                    Err(broadcast::error::RecvError::Closed) => break,
                };
                if let Some(id) = event["params"]["id"].as_str() {
                    if event["event"] == "device.removed" {
                        let _ = removed.send((path.clone(), id.into()));
                    }
                }
                if event["event"] == "device.added"
                    || event["event"] == "device.removed"
                    || event.get("_fault").is_some()
                {
                    sequence += 1;
                    let _ = events.send(CoreEvent {
                        session_id: String::new(),
                        generation: 1,
                        sequence,
                        kind: CoreEventKind::DevicesChanged,
                        payload: json!({"sdk_path":path,"event":event}).to_string(),
                    });
                }
                if event.get("_fault").is_some() {
                    let _ = removed.send((path.clone(), "*".into()));
                    break;
                }
            }
        });
        if let Err(error) = peer
            .request("device.enable", json!({}), Duration::from_secs(30))
            .await
        {
            let _ = peer.terminate().await;
            return Err(error);
        }
        peers.insert(sdk.path, peer.clone());
        Ok(peer)
    }
    pub(crate) async fn devices(&self, sdk_path: &str) -> Result<Vec<DeviceInfo>> {
        let peer = self.peer(sdk_path).await?;
        parse_devices(
            peer.request("device.getDevices", json!({}), Duration::from_secs(30))
                .await?,
        )
    }
    pub(crate) async fn emulators(&self, sdk_path: &str) -> Result<Vec<EmulatorInfo>> {
        let peer = self.peer(sdk_path).await?;
        let values = peer
            .request("emulator.getEmulators", json!({}), Duration::from_secs(30))
            .await?;
        let values = values
            .as_array()
            .context("Invalid emulator list from SDK")?;
        values
            .iter()
            .map(|v| {
                Ok(EmulatorInfo {
                    id: required(v, "id")?,
                    name: required(v, "name")?,
                    platform_type: v["platformType"].as_str().map(str::to_owned),
                })
            })
            .collect()
    }
    pub(crate) async fn launch(&self, sdk_path: &str, emulator_id: &str) -> Result<DeviceInfo> {
        let peer = self.peer(sdk_path).await?;
        // Subscribe before launch so fast simulator readiness cannot be missed.
        let mut receiver = peer.events.subscribe();
        let before = parse_devices(
            peer.request("device.getDevices", json!({}), Duration::from_secs(30))
                .await?,
        )?;
        if let Some(device) = before.iter().find(|d| matches_emulator(d, emulator_id)) {
            return Ok(device.clone());
        }
        let emulator = self
            .emulators(sdk_path)
            .await?
            .into_iter()
            .find(|e| e.id == emulator_id)
            .context("Unknown emulator")?;
        peer.request(
            "emulator.launch",
            json!({"emulatorId":emulator_id,"coldBoot":false}),
            Duration::from_secs(60),
        )
        .await?;
        tokio::time::timeout(Duration::from_secs(120), async {
            loop {
                let event = receiver
                    .recv()
                    .await
                    .map_err(|e| anyhow!("Device readiness stream failed: {e}"))?;
                if let Some(error) = event["_fault"].as_str() {
                    return Err(anyhow!(error.to_owned()));
                }
                if event["event"] == "device.added" {
                    let device = parse_device(&event["params"])?;
                    // iOS's daemon emulator ID is a launcher, not the simulator UDID.
                    let fresh_ios = emulator.platform_type.as_deref() == Some("ios")
                        && device.platform_type.as_deref() == Some("ios")
                        && device.emulator
                        && !before.iter().any(|old| old.id == device.id);
                    if matches_emulator(&device, emulator_id) || fresh_ios {
                        return Ok(device);
                    }
                }
            }
        })
        .await
        .context("Emulator launched but no ready device was reported within 120 seconds")?
    }
    pub(crate) async fn shutdown(&self) {
        let peers = std::mem::take(&mut *self.peers.lock().await);
        for peer in peers.values() {
            let _ = peer
                .request("daemon.shutdown", json!({}), Duration::from_secs(3))
                .await;
            let _ = peer.terminate().await;
        }
    }
}
fn required(v: &Value, key: &str) -> Result<String> {
    v[key]
        .as_str()
        .map(str::to_owned)
        .with_context(|| format!("Missing {key} in SDK device response"))
}
fn parse_device(v: &Value) -> Result<DeviceInfo> {
    Ok(DeviceInfo {
        id: required(v, "id")?,
        name: required(v, "name")?,
        platform: required(v, "platform")?,
        platform_type: v["platformType"].as_str().map(str::to_owned),
        emulator: v["emulator"].as_bool().unwrap_or(false),
        emulator_id: v["emulatorId"].as_str().map(str::to_owned),
    })
}
fn parse_devices(value: Value) -> Result<Vec<DeviceInfo>> {
    value
        .as_array()
        .context("Invalid device list from SDK")?
        .iter()
        .map(parse_device)
        .collect()
}
fn matches_emulator(d: &DeviceInfo, id: &str) -> bool {
    d.id == id || d.emulator_id.as_deref() == Some(id)
}

#[cfg(all(test, unix))]
mod tests {
    use super::*;
    #[tokio::test]
    async fn emulator_launch_waits_for_device_added_not_command_ack() {
        let sdk = crate::session::tests::fake_sdk(false);
        let (events, _) = broadcast::channel(100);
        let manager = DeviceManager::new(events);
        let start = std::time::Instant::now();
        let device = manager
            .launch(sdk.path().to_str().unwrap(), "fixture-emulator")
            .await
            .unwrap();
        assert_eq!(device.id, "ready-device");
        assert!(start.elapsed() >= Duration::from_millis(140));
        manager.shutdown().await;
    }
    #[tokio::test]
    async fn failed_device_enable_cleans_unregistered_daemon() {
        let sdk = crate::session::tests::fake_sdk(false);
        let launcher = sdk.path().join("bin/flutter");
        let script = std::fs::read_to_string(&launcher).unwrap().replace(
            "print(json.dumps([{'id':request['id'],'result':result}]),flush=True)",
            "print(json.dumps([{'id':request['id'],'error':'enable failed'}]),flush=True)",
        );
        std::fs::write(launcher, script).unwrap();
        let (events, _) = broadcast::channel(100);
        let manager = DeviceManager::new(events);
        assert!(manager.devices(sdk.path().to_str().unwrap()).await.is_err());
        assert!(manager.peers.lock().await.is_empty());
        let requests: Vec<Value> = std::fs::read_to_string(sdk.path().join("requests.jsonl"))
            .unwrap()
            .lines()
            .map(|line| serde_json::from_str(line).unwrap())
            .collect();
        let pid = requests
            .iter()
            .find(|value| value["invocation"][0] == "daemon")
            .unwrap()["pid"]
            .as_i64()
            .unwrap();
        assert_eq!(unsafe { libc::kill(pid as i32, 0) }, -1);
    }
}
