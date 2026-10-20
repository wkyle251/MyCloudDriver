//! A demand-driven allowance shared by acquisition and analysis. It is a soft
//! admission envelope, not a preallocation or a fixed fraction of system RAM.
use super::*;
use filetwin_core::{
    api::{LiveResources, WorkCounts},
    memory_control::system_memory,
};

pub(super) fn physical_memory() -> u64 {
    system_memory().physical_bytes
}
pub(super) fn initial_budget(physical: u64) -> u64 {
    (physical / 8).clamp(512 << 20, 2 << 30).min(physical)
}

#[derive(Default, Debug, Clone, Copy)]
struct Demand {
    download_used: u64,
    download_required: u64,
    download_forecast: u64,
    download_minimum: u64,
    download_incomplete: u64,
    staging_used: u64,
    staging_required: u64,
    staging_minimum: u64,
    analysis_used: u64,
    analysis_required: u64,
    analysis_forecast: u64,
    analysis_growth: u64,
    analysis_transfer: u64,
    analysis_active: u64,
}
impl Demand {
    fn used(self) -> u64 {
        self.download_used
            .saturating_add(self.staging_used)
            .saturating_add(self.analysis_used)
    }
}
#[derive(Debug, Clone, Copy)]
struct Plan {
    total: u64,
    download: u64,
    staging: u64,
    analysis: u64,
    pressure: u32,
}

pub(super) struct Governor {
    physical: u64,
    total: u64,
    pressure: u32,
    recovery_until: Duration,
    last_update: Option<Instant>,
    started: Instant,
    external: bool,
    workers: usize,
    last_demand: Demand,
}
impl Governor {
    pub fn new(external: bool, workers: usize) -> Self {
        Self::with_memory(physical_memory(), external, workers)
    }
    fn with_memory(physical: u64, external: bool, workers: usize) -> Self {
        Self {
            physical,
            total: initial_budget(physical),
            pressure: 1,
            recovery_until: Duration::ZERO,
            last_update: None,
            started: Instant::now(),
            external,
            workers,
            last_demand: Demand::default(),
        }
    }
    fn plan(&mut self, demand: Demand, pressure: u32, now: Duration) -> Plan {
        self.last_demand = demand;
        let used = demand.used();
        if pressure >= 2 {
            self.recovery_until = now + Duration::from_secs(30);
            if pressure >= 4 {
                self.total = used;
            } else if self.pressure < 2 {
                self.total = (self.total * 3 / 4).max(used);
            }
        } else if now >= self.recovery_until {
            let source_need = demand
                .download_required
                .max(demand.download_forecast)
                .max(demand.download_used)
                .saturating_add(demand.staging_required.max(demand.staging_used))
                .saturating_add(demand.analysis_used)
                .saturating_add(memory::ANALYSIS_HEADROOM);
            let analysis_need = used.saturating_add(demand.analysis_growth);
            let needed = source_need.max(analysis_need);
            if needed > self.total {
                // Grow on useful demand, allowing pressure signals time to react.
                self.total = needed.min(
                    self.total
                        .saturating_mul(2)
                        .max(initial_budget(self.physical)),
                );
            }
        }
        self.pressure = pressure;
        self.total = self.total.max(used).min(self.physical).max(1);
        if pressure >= 4 {
            return Plan { total: self.total, download: demand.download_used,
                staging: 0, analysis: demand.analysis_used, pressure };
        }
        if pressure == 2 {
            return self.warning_drain(demand);
        }
        let pending_sources = demand
            .download_required
            .saturating_add(demand.staging_required);
        let acquisition_must_drain = self.total >= self.physical
            && demand.download_incomplete > 0
            && demand
                .analysis_required
                .saturating_sub(demand.analysis_used)
                .saturating_sub(demand.analysis_transfer)
                > self.total.saturating_sub(used);
        let analysis = if acquisition_must_drain {
            // A decoder retry cannot borrow bytes still held by a partial
            // original. Let that original finish and reach the ready queue;
            // analysing it can release the RAM needed by the larger retry.
            demand.analysis_used.max(
                self.total.saturating_sub(
                    demand
                        .download_minimum
                        .saturating_add(demand.staging_used)
                        .saturating_add(memory::ANALYSIS_HEADROOM),
                ),
            )
        } else {
            demand
                .analysis_forecast
                .max(demand.analysis_required)
                .max(demand.analysis_used)
                .max(if demand.analysis_required == 0 {
                    if pending_sources > self.total / 2 {
                        memory::ANALYSIS_HEADROOM.min(self.total / 2)
                    } else {
                        self.total / 2
                    }
                } else {
                    0
                })
        }
        .min(self.total);
        let sources = self.total.saturating_sub(analysis);
        let download_need = demand
            .download_required
            .max(demand.download_forecast)
            .max(demand.download_used);
        let staging_need = demand.staging_required.max(demand.staging_used);
        let (download, staging) = if download_need > 0 && staging_need > 0 {
            // Prefer completing the smaller source claim; held larger buffers
            // stay charged and can borrow the bank again after that handoff.
            if acquisition_must_drain {
                let download = sources.min(demand.download_minimum);
                (download, sources - download)
            } else if download_need <= staging_need {
                let download = sources.min(download_need);
                (download, sources - download)
            } else {
                let staging = sources.min(staging_need);
                (sources - staging, staging)
            }
        } else if staging_need > 0 || (!self.external && download_need == 0) {
            (0, sources)
        } else {
            (sources, 0)
        };
        Plan {
            total: self.total,
            download,
            staging,
            analysis,
            pressure,
        }
    }
    fn warning_drain(&mut self, demand: Demand) -> Plan {
        let mut plan = Plan {
            total: self.total,
            download: demand.download_used,
            staging: 0,
            analysis: demand.analysis_used,
            pressure: 2,
        };
        // Existing reservations already cover active calculations. Keep them
        // intact, but do not start another calculation while they drain.
        if demand.analysis_active > 0 {
            return plan;
        }
        let analysis_need = (demand.analysis_required > demand.analysis_used).then(|| {
            demand.used().saturating_add(demand.analysis_required
                .saturating_sub(demand.analysis_used).saturating_sub(demand.analysis_transfer))
        });
        let source_need = (demand.download_incomplete > 0).then(|| {
            demand.download_minimum.saturating_add(demand.staging_used)
                .saturating_add(demand.analysis_used).saturating_add(memory::ANALYSIS_HEADROOM)
        });
        let analysis_fits = analysis_need.filter(|need| *need <= self.physical);
        let source_fits = source_need.filter(|need| *need <= self.physical);
        if let Some(need) = analysis_fits.filter(|analysis| source_fits.is_none_or(|source| *analysis <= source)) {
            // This is a drain allowance for one held input, not forecast-driven
            // growth. Only its original receives the zero-copy transfer credit.
            self.total = self.total.max(need).min(self.physical);
            plan.analysis = demand.analysis_required;
        } else if let Some(need) = source_fits {
            self.total = self.total.max(need).min(self.physical);
            plan.download = demand.download_minimum;
        } else if analysis_need.is_some() || source_need.is_some() {
            // Let the existing physical-capacity retry handling release an
            // impossible retained retry; a soft warning cap must not hide it.
            self.total = self.physical;
            plan.download = demand.download_minimum.min(self.physical
                .saturating_sub(demand.staging_used).saturating_sub(demand.analysis_used)
                .saturating_sub(memory::ANALYSIS_HEADROOM));
        } else if demand.used() == 0 && demand.staging_minimum > 0 {
            // A persistent warning can otherwise close both banks forever:
            // no held input remains to drain, but every new read needs RAM.
            // Fund only the smallest native read and its completion headroom.
            // The staging pool serializes reads while memory_draining is set;
            // the next ready-input update closes this bank before handoff.
            let need = demand.staging_minimum.saturating_add(memory::ANALYSIS_HEADROOM);
            if need <= self.physical {
                self.total = self.total.max(need).min(self.physical);
                plan.staging = demand.staging_minimum;
            }
        }
        plan.total = self.total.max(1);
        // Held staging leases remain charged in demand.used(). A zero bank
        // lets their reads finish without letting a handoff fund a new copy.
        plan
    }
    pub fn update(
        &mut self,
        work: &WorkCounts,
        memory: &memory::Budget,
        token: &filetwin_core::api::CancellationToken,
    ) {
        self.update_with_pressure(work, memory, token, system_memory().pressure);
    }
    fn update_with_pressure(
        &mut self,
        work: &WorkCounts,
        memory: &memory::Budget,
        token: &filetwin_core::api::CancellationToken,
        pressure: u32,
    ) {
        let now = Instant::now();
        if self
            .last_update
            .is_some_and(|last| now.duration_since(last) < Duration::from_millis(250))
        {
            return;
        }
        self.last_update = Some(now);
        let demand = Demand {
            download_used: memory.used(),
            download_required: memory.take_required(),
            download_forecast: memory.forecast(),
            download_minimum: memory.minimum_limit(),
            download_incomplete: memory.usage.incomplete.load(Ordering::Acquire),
            staging_used: work.original_memory_bytes,
            staging_required: work.staging_memory_required,
            staging_minimum: work.staging_memory_minimum,
            analysis_used: work
                .memory_in_use
                .saturating_sub(work.original_memory_bytes),
            analysis_required: work.analysis_memory_required,
            analysis_forecast: work.analysis_memory_forecast,
            analysis_growth: work.analysis_growth_bytes,
            analysis_transfer: work.analysis_transfer_bytes,
            analysis_active: work.hashing.saturating_add(work.encoding),
        };
        let plan = self.plan(
            demand,
            pressure,
            now.duration_since(self.started),
        );
        memory.usage.completion_required.store(
            demand
                .download_minimum
                .saturating_add(memory::ANALYSIS_HEADROOM),
            Ordering::Release,
        );
        // Reduce immediately; increases wait until the coordinator has reduced
        // the other source bank and checked all retained reservations.
        memory.auto_reduce(plan.download, plan.pressure);
        token.set_memory_draining(plan.pressure == 2);
        token.update_resources(LiveResources {
            workers: self.workers,
            memory_bytes: plan.analysis.max(1),
            staging_bytes: plan.staging,
            total_memory_bytes: Some(plan.total),
            acquisition_paused: plan.pressure >= 4,
            external_memory_bytes: Some(plan.download.min(memory.ceiling())),
        });
    }
    pub fn annotate(&self, event: &mut Value) {
        event["work"]["automatic_memory"] = true.into();
        event["work"]["memory_limit"] = self.total.into();
        event["work"]["memory_pressure"] = self.pressure.into();
        event["work"]["download_incomplete_buffers"] = self.last_demand.download_incomplete.into();
        event["work"]["download_completion_required"] = self.last_demand.download_minimum.into();
        event["work"]["download_memory_required"] = self.last_demand.download_required.into();
        event["work"]["original_memory_limit"] = event["work"]["original_memory_limit"]
            .as_u64()
            .unwrap_or(0)
            .saturating_add(event["work"]["staging_memory_limit"].as_u64().unwrap_or(0))
            .into();
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn persistent_warning_reopens_only_the_smallest_native_read_when_everything_has_drained() {
        let mut governor = Governor::with_memory(16 << 30, true, 8);
        governor.total = 2_727_390_887;
        let waiting = Demand { staging_required: 2_509_723_543,
            staging_minimum: 204_416_795, ..Default::default() };
        let first = governor.plan(waiting, 2, Duration::ZERO);
        assert_eq!(first.staging, waiting.staging_minimum);
        assert_eq!((first.download, first.analysis), (0, 0));
        assert!(first.total >= first.staging + memory::ANALYSIS_HEADROOM);
        let reading = Demand { staging_used: first.staging, ..waiting };
        assert_eq!(governor.plan(reading, 2, Duration::from_secs(1)).staging, 0,
            "A warning must not admit another original while the first drains");
        let ready = Demand { staging_used: first.staging, analysis_transfer: first.staging,
            analysis_required: first.staging + memory::ANALYSIS_HEADROOM, ..waiting };
        let handoff = governor.plan(ready, 2, Duration::from_secs(2));
        assert_eq!(handoff.staging, 0);
        assert_eq!(handoff.analysis, ready.analysis_required);
        let active = Demand { analysis_used: handoff.analysis, analysis_active: 1, ..waiting };
        assert_eq!(governor.plan(active, 2, Duration::from_secs(3)).staging, 0);
        assert_eq!(governor.plan(waiting, 2, Duration::from_secs(4)).staging, first.staging,
            "A persistent warning must still allow the next file after completion");
        let critical = governor.plan(waiting, 4, Duration::from_secs(5));
        assert_eq!((critical.download, critical.staging, critical.analysis), (0, 0, 0));
    }

    #[test]
    fn persistent_warning_native_pipeline_completes_without_waiting_for_pressure_to_clear() {
        use filetwin_core::{Encoder, api::{CancellationToken, EncodeRequest, EncodeSource, EncoderConfig}};
        let root = tempfile::tempdir().unwrap();
        let canonical = root.path().canonicalize().unwrap();
        let directory = canonical.join("input");
        let models = canonical.join("models");
        let temporary = canonical.join("temporary");
        for path in [&directory, &models, &temporary] { std::fs::create_dir(path).unwrap(); }
        let mut sources = Vec::new();
        for index in 0..4 {
            let path = directory.join(format!("{index}.txt"));
            std::fs::write(&path, "A garden with green trees, flowers and a wooden bench. ".repeat(40)).unwrap();
            sources.push(EncodeSource::new(format!("{index}.txt"), path));
        }
        let memory = memory::Budget::new(256 << 20);
        memory.enable_automatic(1 << 30);
        let mut config = EncoderConfig::new(models, temporary);
        config.memory_scheduling = true;
        config.memory_staging = true;
        config.memory_bytes = 1;
        config.staging_bytes = 1;
        config.memory_ceiling = Some(1 << 30);
        config.total_memory_bytes = Some(512 << 20);
        config.external_memory = Some(memory.usage.clone());
        config.workers = 4;
        let token = CancellationToken::default();
        let mut governor = Governor::with_memory(1 << 30, true, 4);
        let started = Instant::now();
        let mut sources = sources.into_iter();
        let mut saw_read = false;
        let result = Encoder::new(config).unwrap().encode_sources(
            &EncodeRequest::new(directory), &token, || Ok(sources.next()), |progress| {
                if started.elapsed() > Duration::from_secs(15) { token.cancel(); }
                if let Some(work) = &progress.work {
                    assert!(work.reading <= 1, "Warning recovery admitted parallel source copies");
                    assert!(work.hashing + work.encoding <= 1);
                    saw_read |= work.original_memory_bytes > 0;
                    governor.update_with_pressure(work, &memory, &token, 2);
                }
            }).unwrap();
        assert!(!result.summary.cancelled, "Persistent warning stranded an idle pipeline");
        assert!(result.complete && saw_read, "{:?}: {:?}", result.summary, result.files);
        assert_eq!(result.summary.counts.files_ready, 4);
        assert_eq!(result.files.len(), 4);
    }

    #[test]
    fn persistent_warning_native_exact_fit_keeps_unused_source_banks_at_zero() {
        let mut governor = Governor::with_memory(16 << 30, true, 8);
        governor.total = 12 << 30;
        let demand = Demand {
            staging_used: 6_486_996_157,
            staging_required: 12_569_241_978,
            analysis_required: 13_106_112_890,
            analysis_forecast: 13_106_112_890,
            analysis_growth: 6_619_116_733,
            analysis_transfer: 6_486_996_157,
            ..Default::default()
        };
        for second in 0..120 {
            let plan = governor.plan(demand, 2, Duration::from_secs(second));
            assert_eq!(plan.total, demand.analysis_required);
            assert_eq!(plan.analysis, demand.analysis_required);
            assert_eq!((plan.download, plan.staging), (0, 0));
            assert_eq!(plan.total - demand.used(), plan.analysis - demand.analysis_transfer,
                "Every byte is needed for this existing original; no empty bank may consume one");
        }
    }
    #[test]
    fn persistent_warning_drains_a_held_original_above_the_reduced_soft_cap() {
        let mut governor = Governor::with_memory(16 << 30, true, 8);
        governor.total = 16 << 30;
        let demand = Demand {
            download_used: 6 << 30,
            analysis_required: 13 << 30,
            analysis_forecast: 60 << 30,
            analysis_growth: 54 << 30,
            analysis_transfer: 6 << 30,
            ..Default::default()
        };
        for second in 0..120 {
            let plan = governor.plan(demand, 2, Duration::from_secs(second));
            assert_eq!(plan.total, 13 << 30);
            assert_eq!(plan.analysis, demand.analysis_required);
            assert_eq!(plan.download, demand.download_used);
            assert_eq!(plan.staging, 0);
            assert!(plan.analysis.saturating_sub(demand.analysis_transfer)
                <= plan.total.saturating_sub(demand.used()));
            assert!(plan.total <= governor.physical);
        }
        let active = Demand { analysis_used: 13 << 30, analysis_active: 1,
            analysis_required: 15 << 30, analysis_forecast: 60 << 30,
            staging_required: 20 << 30, download_required: 20 << 30, ..Default::default() };
        let plan = governor.plan(active, 2, Duration::from_secs(121));
        assert_eq!(plan.analysis, active.analysis_used, "An active analysis must finish before another is admitted");
        assert_eq!((plan.download, plan.staging), (0, 0), "Warning must not fund new source buffers");
        let drained = governor.plan(Demand::default(), 2, Duration::from_secs(122));
        assert_eq!((drained.download, drained.staging, drained.analysis), (0, 0, 0));
    }
    #[tokio::test]
    async fn persistent_warning_completes_an_existing_download_but_admits_no_new_one() {
        let cancel = AtomicBool::new(false);
        let budget = memory::Budget::new(16 << 30);
        budget.enable_automatic(16 << 30);
        let original = budget.stream(6 << 30, &cancel).await.unwrap();
        original.grow(4 << 30, &cancel).await.unwrap();
        let mut governor = Governor::with_memory(16 << 30, true, 8);
        governor.total = 16 << 30;
        let demand = Demand { download_used: budget.used(), download_minimum: budget.minimum_limit(),
            download_incomplete: 1, staging_required: 20 << 30, ..Default::default() };
        let plan = governor.plan(demand, 2, Duration::ZERO);
        assert_eq!(plan.download, demand.download_minimum);
        assert!(plan.total >= plan.download + memory::ANALYSIS_HEADROOM);
        assert!(plan.total <= governor.physical);
        assert_eq!(plan.staging, 0, "New local reads must not compete with held originals");
        budget.auto_resize(plan.download, 2);
        tokio::time::timeout(Duration::from_millis(100), original.grow(6 << 30, &cancel)).await.unwrap().unwrap();
        assert!(tokio::time::timeout(Duration::from_millis(30), budget.stream(1 << 20, &cancel)).await.is_err(),
            "Warning drain must keep new full-download admission closed");
        original.finish(6 << 30);
        let ready = Demand { download_used: budget.used(), analysis_required: (12 << 30) + (512 << 20),
            analysis_transfer: 6 << 30, ..Default::default() };
        let plan = governor.plan(ready, 2, Duration::from_secs(1));
        assert!(plan.analysis >= ready.analysis_required);
        assert!(plan.total - ready.used() >= plan.analysis - ready.analysis_transfer);
        drop(original);
        assert_eq!(budget.used(), 0);
    }
    #[test]
    fn warning_preserves_active_reservations_and_never_exceeds_physical_ram() {
        let mut governor = Governor::with_memory(16 << 30, true, 8);
        governor.total = 16 << 30;
        let active = Demand { download_used: 4 << 30, download_minimum: 12 << 30,
            download_incomplete: 1, staging_used: 1 << 30, analysis_used: 7 << 30,
            analysis_active: 1, analysis_required: 15 << 30, ..Default::default() };
        let plan = governor.plan(active, 2, Duration::ZERO);
        assert_eq!((plan.analysis, plan.download, plan.staging), (7 << 30, 4 << 30, 0));
        let impossible = Demand { analysis_used: 7 << 30, analysis_required: 18 << 30,
            analysis_transfer: 0, ..Default::default() };
        let plan = governor.plan(impossible, 2, Duration::from_secs(1));
        assert_eq!(plan.total, governor.physical);
        assert_eq!(plan.analysis, impossible.analysis_used);
        assert!(plan.download + plan.staging + plan.analysis <= governor.physical);
    }
    #[test]
    fn a_large_retry_cannot_starve_the_partial_original_that_would_free_its_ram() {
        let mut governor = Governor::with_memory(64 << 30, true, 18);
        governor.total = 64 << 30;
        let demand = Demand {
            download_used: 10 << 30,
            download_required: 40 << 30,
            download_minimum: 40 << 30,
            download_incomplete: 1,
            analysis_used: 10 << 30,
            analysis_required: 60 << 30,
            analysis_forecast: 60 << 30,
            analysis_growth: 50 << 30,
            ..Default::default()
        };
        let plan = governor.plan(demand, 1, Duration::ZERO);
        assert!(
            plan.download >= demand.download_minimum,
            "A waiting decoder took the RAM needed to finish acquisition"
        );
        assert!(plan.analysis < demand.analysis_required);
        let ready = Demand {
            download_used: 20 << 30,
            analysis_used: 10 << 30,
            analysis_required: (50 << 30) + (512 << 20),
            analysis_forecast: 110 << 30,
            analysis_transfer: 20 << 30,
            analysis_growth: (20 << 30) + (512 << 20),
            ..Default::default()
        };
        let plan = governor.plan(ready, 1, Duration::from_secs(1));
        assert!(
            plan.analysis >= ready.analysis_required,
            "The smaller ready original must be able to drain"
        );
    }
    #[test]
    fn grows_past_old_caps_only_when_files_need_the_space() {
        let mut governor = Governor::with_memory(64 << 30, true, 512);
        assert_eq!(
            governor.plan(Demand::default(), 1, Duration::ZERO).total,
            2 << 30
        );
        let demand = Demand {
            download_required: 48 << 30,
            ..Default::default()
        };
        let mut plan = governor.plan(demand, 1, Duration::from_secs(1));
        for second in 2..8 {
            plan = governor.plan(demand, 1, Duration::from_secs(second));
        }
        assert!(plan.download >= 48 << 30);
        assert!(plan.total <= 64 << 30);
        assert_eq!(plan.analysis + plan.download + plan.staging, plan.total);
    }
    #[test]
    fn ready_original_borrows_the_acquisition_allowance_without_a_second_copy() {
        let mut governor = Governor::with_memory(32 << 30, true, 256);
        governor.total = 22 << 30;
        let demand = Demand {
            download_used: 20 << 30,
            analysis_required: (20 << 30) + (512 << 20),
            analysis_forecast: (20 << 30) + (512 << 20),
            analysis_growth: 512 << 20,
            ..Default::default()
        };
        let plan = governor.plan(demand, 1, Duration::ZERO);
        assert_eq!(plan.total, 22 << 30);
        assert!(plan.analysis >= demand.analysis_required);
        assert!(plan.download < demand.download_used);
        assert!(plan.total - demand.used() >= demand.analysis_growth);
    }
    #[test]
    fn pressure_retains_buffers_and_holds_growth_until_recovery() {
        let mut governor = Governor::with_memory(64 << 30, true, 512);
        governor.total = 16 << 30;
        let demand = Demand {
            download_used: 4 << 30,
            download_required: 32 << 30,
            ..Default::default()
        };
        let warning = governor.plan(demand, 2, Duration::from_secs(1));
        assert_eq!(warning.total, 12 << 30);
        assert_eq!(
            governor.plan(demand, 2, Duration::from_secs(2)).total,
            warning.total
        );
        let critical = governor.plan(demand, 4, Duration::from_secs(3));
        assert_eq!(critical.total, demand.used());
        assert_eq!(critical.analysis, 0);
        assert_eq!(
            governor.plan(demand, 1, Duration::from_secs(32)).total,
            critical.total
        );
        assert!(governor.plan(demand, 1, Duration::from_secs(34)).total > critical.total);
    }
    #[test]
    fn large_local_original_can_borrow_idle_analysis_space() {
        let mut governor = Governor::with_memory(32 << 30, false, 256);
        let demand = Demand {
            staging_required: 24 << 30,
            ..Default::default()
        };
        let mut plan = governor.plan(demand, 1, Duration::ZERO);
        for second in 1..8 {
            plan = governor.plan(demand, 1, Duration::from_secs(second));
        }
        assert!(plan.staging >= demand.staging_required);
        assert_eq!(plan.download, 0);
    }
}
