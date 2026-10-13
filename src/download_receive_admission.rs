//! File-body admission is independent of verification. A resumed verifier may
//! finish its disk work while receiving slots are full, then wait here without
//! retaining read admission. Existing bodies survive a reduced target.
use std::{collections::VecDeque, sync::{Arc, Mutex}};
use tokio::sync::Notify;

struct Waiter { number: u64, wake: Arc<Notify> }
struct State { limit: usize, active: usize, next: u64, waiting: VecDeque<Waiter> }
impl State {
    fn wake_next(&self) {
        if self.active < self.limit {
            if let Some(waiter) = self.waiting.front() { waiter.wake.notify_one(); }
        }
    }
}
pub(crate) struct NetworkSlots { state: Mutex<State> }
pub(crate) struct NetworkSlot(Arc<NetworkSlots>);
impl NetworkSlots {
    pub(crate) fn new(limit: usize) -> Arc<Self> {
        Arc::new(Self { state: Mutex::new(State { limit: limit.max(1), active: 0, next: 0, waiting: VecDeque::new() }) })
    }
    pub(crate) fn set_limit(&self, limit: usize) {
        let mut state = self.state.lock().unwrap();
        if state.limit == limit.max(1) { return; }
        state.limit = limit.max(1);state.wake_next();
    }
    pub(crate) fn available(&self) -> bool {
        let state = self.state.lock().unwrap();state.active < state.limit && state.waiting.is_empty()
    }
    pub(crate) fn active(&self) -> usize { self.state.lock().unwrap().active }
    pub(crate) fn waiting(&self) -> usize { self.state.lock().unwrap().waiting.len() }
    pub(crate) fn try_acquire(self: &Arc<Self>) -> Option<NetworkSlot> {
        let mut state = self.state.lock().unwrap();
        if state.active >= state.limit || !state.waiting.is_empty() { return None; }
        state.active += 1;Some(NetworkSlot(self.clone()))
    }
    pub(crate) async fn acquire(self: &Arc<Self>) -> NetworkSlot {
        let wake = Arc::new(Notify::new());
        let number = {
            let mut state = self.state.lock().unwrap();
            let number = state.next;state.next = state.next.wrapping_add(1);
            state.waiting.push_back(Waiter { number, wake: wake.clone() });number
        };
        let _waiting = Waiting(self.clone(), number);
        loop {
            let notified = wake.notified();tokio::pin!(notified);notified.as_mut().enable();
            {
                let mut state = self.state.lock().unwrap();
                if state.active < state.limit && state.waiting.front().is_some_and(|waiter| waiter.number == number) {
                    state.waiting.pop_front();state.active += 1;
                    state.wake_next();return NetworkSlot(self.clone());
                }
            }
            notified.await;
        }
    }
}
struct Waiting(Arc<NetworkSlots>, u64);
impl Drop for Waiting {
    fn drop(&mut self) {
        let mut state = self.0.state.lock().unwrap();
        let was_head = state.waiting.front().is_some_and(|waiter| waiter.number == self.1);
        state.waiting.retain(|waiter| waiter.number != self.1);
        if was_head { state.wake_next(); }
    }
}
impl Drop for NetworkSlot {
    fn drop(&mut self) {
        let mut state = self.0.state.lock().unwrap();state.active -= 1;state.wake_next();
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    #[tokio::test]
    async fn one_free_slot_wakes_only_the_fifo_head_and_cancelling_it_wakes_its_successor() {
        use std::{future::Future, sync::atomic::{AtomicUsize, Ordering}, task::{Context, Poll}};
        struct Wakes(AtomicUsize);
        impl futures_util::task::ArcWake for Wakes {
            fn wake_by_ref(value: &Arc<Self>) { value.0.fetch_add(1, Ordering::SeqCst); }
        }
        let gate = NetworkSlots::new(1);let occupied = gate.try_acquire().unwrap();
        let mut pending = VecDeque::new();
        for _ in 0..1_000 {
            let counter = Arc::new(Wakes(AtomicUsize::new(0)));
            let waker = futures_util::task::waker(counter.clone());
            let mut future = Box::pin(gate.acquire());
            assert!(future.as_mut().poll(&mut Context::from_waker(&waker)).is_pending());
            pending.push_back((future, counter));
        }
        drop(occupied);
        assert_eq!(pending.iter().map(|(_, counter)| counter.0.load(Ordering::SeqCst)).sum::<usize>(), 1,
            "A completed body must not wake every prepared receiver");
        drop(pending.pop_front());
        assert_eq!(pending.front().unwrap().1.0.load(Ordering::SeqCst), 1);
        gate.set_limit(3);
        let mut admitted = Vec::new();
        for _ in 0..3 {
            let (mut future, counter) = pending.pop_front().unwrap();
            assert!(counter.0.load(Ordering::SeqCst) > 0);
            let waker = futures_util::task::waker(counter);
            match future.as_mut().poll(&mut Context::from_waker(&waker)) {
                Poll::Ready(slot) => admitted.push(slot), Poll::Pending => panic!("Available slots must fill without a broadcast"),
            }
        }
        assert_eq!(gate.active(), 3);
        assert!(pending.iter().all(|(_, counter)| counter.0.load(Ordering::SeqCst) == 0));
        drop(admitted);drop(pending);assert_eq!(gate.active(), 0);assert_eq!(gate.waiting(), 0);
        assert!(gate.try_acquire().is_some());
    }
    #[tokio::test]
    async fn receiving_target_changes_keep_bodies_alive_and_cancelled_waiters_do_not_block() {
        let gate = NetworkSlots::new(2);
        let a = gate.try_acquire().unwrap();let b = gate.try_acquire().unwrap();
        gate.set_limit(1);assert_eq!(gate.active(), 2);assert!(!gate.available());
        let cancelled_gate=gate.clone();let cancelled=tokio::spawn(async move { cancelled_gate.acquire().await });
        tokio::task::yield_now().await;
        let following_gate=gate.clone();let following=tokio::spawn(async move { following_gate.acquire().await });
        tokio::task::yield_now().await;assert_eq!(gate.waiting(), 2);
        cancelled.abort();let _=cancelled.await;drop(a);
        assert_eq!(gate.active(), 1);assert!(!following.is_finished());
        drop(b);let held=tokio::time::timeout(std::time::Duration::from_secs(1), following).await.unwrap().unwrap();
        assert_eq!(gate.active(), 1);assert_eq!(gate.waiting(), 0);
        gate.set_limit(2);assert!(gate.available());
        drop(held);assert_eq!(gate.active(), 0);
    }
}
