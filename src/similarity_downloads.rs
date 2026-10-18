//! Live download telemetry. Values contain display names, never signed links,
//! credentials or response bodies. Dropped/cancelled fetches remove their row.
use super::*;

#[derive(Clone, Serialize)]
struct Row {
    id: u64,
    name: String,
    received: u64,
    total: u64,
    speed: f64,
    state: &'static str,
    attempt: u32,
    retry_seconds: u64,
    on_demand: bool,
    cloud: bool,
}
struct Entry {
    row: Row,
    sampled: Instant,
    sample_bytes: u64,
    retry_at: Option<Instant>,
}
#[derive(Default)]
pub(super) struct Downloads {
    rows: Mutex<HashMap<u64, Entry>>,
    next: AtomicU64,
}
pub(in crate::similarity) struct Ticket {
    downloads: Arc<Downloads>,
    id: u64,
}
impl Drop for Ticket {
    fn drop(&mut self) {
        self.downloads.rows.lock().unwrap().remove(&self.id);
    }
}
impl Downloads {
    pub fn start(self: &Arc<Self>, name: &str, total: u64) -> Ticket {
        let id = self.next.fetch_add(1, Ordering::Relaxed);
        self.rows.lock().unwrap().insert(
            id,
            Entry {
                row: Row {
                    id,
                    name: name.to_string(),
                    received: 0,
                    total,
                    speed: 0.0,
                    state: "connecting",
                    attempt: 1,
                    retry_seconds: 0,
                    on_demand: false,
                    cloud: true,
                },
                sampled: Instant::now(),
                sample_bytes: 0,
                retry_at: None,
            },
        );
        Ticket {
            downloads: self.clone(),
            id,
        }
    }
    fn speed(entry: &Entry, now: Instant) -> f64 {
        if entry.row.state != "downloading" {
            return 0.0;
        }
        entry.row.speed
            * (-(now.saturating_duration_since(entry.sampled).as_secs_f64() - 1.0).max(0.0) / 3.0)
                .exp()
    }
    pub fn snapshot(&self) -> Value {
        let now = Instant::now();
        let mut rows: Vec<_> = self
            .rows
            .lock()
            .unwrap()
            .values()
            .map(|entry| {
                let mut row = entry.row.clone();
                row.speed = Self::speed(entry, now);
                if let Some(at) = entry.retry_at {
                    let remaining = at.saturating_duration_since(now);
                    row.retry_seconds =
                        remaining.as_secs() + u64::from(remaining.subsec_nanos() > 0);
                }
                row
            })
            .collect();
        rows.sort_by_key(|row| {
            (
                match row.state {
                    "downloading" => 0,
                    "waiting_memory" => 1,
                    "connecting" => 2,
                    "queued" => 3,
                    _ => 4,
                },
                row.id,
            )
        });
        let count = rows.len();
        let speed: f64 = rows.iter().map(|r| r.speed).sum();
        let received_bytes: u64 = rows
            .iter()
            .map(|r| {
                if r.total > 0 {
                    r.received.min(r.total)
                } else {
                    r.received
                }
            })
            .sum();
        let full_received_bytes: u64 = rows.iter().filter(|r| !r.on_demand)
            .map(|r| if r.total > 0 { r.received.min(r.total) } else { r.received }).sum();
        let sampled_received_bytes = received_bytes.saturating_sub(full_received_bytes);
        let cloud_full_received_bytes: u64 = rows.iter().filter(|r| r.cloud && !r.on_demand)
            .map(|r| if r.total > 0 { r.received.min(r.total) } else { r.received }).sum();
        rows.truncate(128);
        json!({"items":rows,"total":count,"omitted":count.saturating_sub(128),"speed":speed,"received_bytes":received_bytes,
            "full_received_bytes":full_received_bytes,"cloud_full_received_bytes":cloud_full_received_bytes,"sampled_received_bytes":sampled_received_bytes})
    }
}
impl Ticket {
    pub fn native(&self) {
        self.downloads.rows.lock().unwrap().get_mut(&self.id).unwrap().row.cloud = false;
    }
    pub fn on_demand(&self) {
        self.downloads.rows.lock().unwrap().get_mut(&self.id).unwrap().row.on_demand = true;
    }
    pub fn id(&self) -> u64 {
        self.id
    }
    pub fn phase(&self, phase: &'static str) {
        self.downloads
            .rows
            .lock()
            .unwrap()
            .get_mut(&self.id)
            .unwrap()
            .row
            .state = phase;
    }
    pub fn begin_attempt(&self, attempt: u32, transferred: u64) {
        let mut rows = self.downloads.rows.lock().unwrap();
        let entry = rows.get_mut(&self.id).unwrap();
        entry.row.attempt = attempt;
        entry.row.received = 0;
        entry.row.speed = 0.0;
        entry.row.state = "connecting";
        entry.row.retry_seconds = 0;
        entry.retry_at = None;
        entry.sample_bytes = transferred;
        entry.sampled = Instant::now();
    }
    pub fn sample(&self, written: u64, total: u64, transferred: u64) -> f64 {
        let mut rows = self.downloads.rows.lock().unwrap();
        let entry = rows.get_mut(&self.id).unwrap();
        entry.row.received = written;
        entry.row.total = total;
        let elapsed = entry.sampled.elapsed().as_secs_f64();
        if elapsed >= 0.2 {
            let rate = transferred.saturating_sub(entry.sample_bytes) as f64 / elapsed;
            entry.row.speed = if entry.row.speed == 0.0 {
                rate
            } else {
                entry.row.speed * 0.7 + rate * 0.3
            };
            entry.sampled = Instant::now();
            entry.sample_bytes = transferred;
        }
        entry.row.speed
    }
    pub fn retry(&self, seconds: u64) {
        let mut rows = self.downloads.rows.lock().unwrap();
        let entry = rows.get_mut(&self.id).unwrap();
        entry.row.state = "retrying";
        entry.row.retry_seconds = seconds;
        entry.row.speed = 0.0;
        entry.retry_at = Some(Instant::now() + Duration::from_secs(seconds.min(86_400)));
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn byte_progress_includes_hidden_rows_and_does_not_count_retransmissions() {
        let downloads = Arc::new(Downloads::default());
        let tickets: Vec<_> = (0..140).map(|_| downloads.start("part.bin", 100)).collect();
        for ticket in &tickets {
            ticket.sample(50, 100, 150);
        }
        let event = downloads.snapshot();
        assert_eq!(event["items"].as_array().unwrap().len(), 128);
        assert_eq!(
            event["received_bytes"], 7_000,
            "Count retained bytes across every file, not wire bytes or the visible 128 rows"
        );
        tickets[0].begin_attempt(2, 150);
        tickets[0].sample(50, 100, 300);
        assert_eq!(downloads.snapshot()["received_bytes"], 7_000);
        drop(tickets);
        assert_eq!(downloads.snapshot()["received_bytes"], 0);
    }
    #[test]
    fn retries_reset_progress_and_paused_or_stalled_streams_do_not_report_old_speed() {
        let downloads = Arc::new(Downloads::default());
        let ticket = downloads.start("example.jpg", 1000);
        ticket.phase("downloading");
        {
            let mut rows = downloads.rows.lock().unwrap();
            rows.get_mut(&ticket.id).unwrap().sampled -= Duration::from_secs(1);
        }
        assert!(ticket.sample(500, 1000, 500) > 0.0);
        let event = downloads.snapshot();
        assert_eq!(event["items"][0]["received"], 500);
        assert!(event["speed"].as_f64().unwrap() > 0.0);
        {
            let mut rows = downloads.rows.lock().unwrap();
            rows.get_mut(&ticket.id).unwrap().sampled -= Duration::from_secs(10);
        }
        assert!(
            downloads.snapshot()["speed"].as_f64().unwrap()
                < event["speed"].as_f64().unwrap() / 10.0,
            "A stalled stream must not retain its old displayed speed"
        );
        ticket.phase("waiting_memory");
        assert_eq!(downloads.snapshot()["speed"], 0.0);
        ticket.retry(3);
        assert_eq!(downloads.snapshot()["items"][0]["retry_seconds"], 3);
        {
            let mut rows = downloads.rows.lock().unwrap();
            *rows.get_mut(&ticket.id).unwrap().retry_at.as_mut().unwrap() -= Duration::from_secs(2);
        }
        assert_eq!(downloads.snapshot()["items"][0]["retry_seconds"], 1);
        ticket.begin_attempt(2, 500);
        assert_eq!(downloads.snapshot()["items"][0]["received"], 0);
        drop(ticket);
        assert_eq!(downloads.snapshot()["total"], 0);
    }
}
