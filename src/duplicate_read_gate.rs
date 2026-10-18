//! Pause excess readers between chunks, preserving their open file and hash.
//! A smaller throughput trial must actually reduce I/O, even with huge files.
use std::{collections::BTreeSet, sync::{Arc, Condvar, Mutex}};

#[derive(Default)]
struct State { limit: usize, next: usize, readers: BTreeSet<usize>, closed: bool }

#[derive(Default)]
pub(super) struct ReadGate { state: Mutex<State>, changed: Condvar }

pub(super) struct Reader { gate: Arc<ReadGate>, id: usize }

pub(super) struct CloseOnDrop(pub Arc<ReadGate>);
impl Drop for CloseOnDrop {
    fn drop(&mut self) {
        self.0.state.lock().unwrap_or_else(|e| e.into_inner()).closed = true;
        self.0.changed.notify_all();
    }
}

impl ReadGate {
    pub fn limit(&self, limit: usize) {
        self.state.lock().unwrap_or_else(|e| e.into_inner()).limit = limit.max(1);
        self.changed.notify_all();
    }
    pub fn active(&self) -> usize {
        let state = self.state.lock().unwrap_or_else(|e| e.into_inner());
        state.readers.len().min(state.limit)
    }
    pub fn register(self: &Arc<Self>) -> Reader {
        let mut state = self.state.lock().unwrap_or_else(|e| e.into_inner());
        let id = state.next; state.next += 1; state.readers.insert(id);
        Reader { gate: self.clone(), id }
    }
}

impl Reader {
    pub fn wait(&self) -> anyhow::Result<()> {
        let mut state = self.gate.state.lock().unwrap_or_else(|e| e.into_inner());
        while !state.closed && state.readers.iter().take(state.limit).all(|id| *id != self.id) {
            state = self.gate.changed.wait(state).unwrap_or_else(|e| e.into_inner());
        }
        anyhow::ensure!(!state.closed, "Duplicate scan stopped");
        Ok(())
    }
}

impl Drop for Reader {
    fn drop(&mut self) {
        self.gate.state.lock().unwrap_or_else(|e| e.into_inner()).readers.remove(&self.id);
        self.gate.changed.notify_all();
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::{sync::mpsc, time::Duration};
    #[test]
    fn shrinking_pauses_existing_readers_and_finishing_promotes_the_next() {
        let gate = Arc::new(ReadGate::default()); gate.limit(2);
        let first = gate.register(); let second = gate.register();
        first.wait().unwrap(); second.wait().unwrap();
        gate.limit(1);
        let (tx, rx) = mpsc::channel();
        let task = std::thread::spawn(move || { second.wait().unwrap(); tx.send(()).unwrap(); });
        assert!(rx.recv_timeout(Duration::from_millis(30)).is_err());
        drop(first);
        rx.recv_timeout(Duration::from_secs(2)).unwrap(); task.join().unwrap();
    }
    #[test]
    fn stopping_wakes_parked_readers() {
        let gate = Arc::new(ReadGate::default()); gate.limit(1);
        let _first = gate.register(); let second = gate.register();
        let task = std::thread::spawn(move || second.wait());
        drop(CloseOnDrop(gate));
        assert!(task.join().unwrap().is_err());
    }
}
