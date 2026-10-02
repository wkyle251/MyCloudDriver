//! Read-only grouping of a saved score matrix. No source, model or worker is
//! opened. Each non-self matrix cell is stored once in the app's saved snapshot.
use super::*;
use std::collections::BTreeMap;

#[derive(Debug, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct GroupQuery {
    pub data_dir: PathBuf,
    pub run_id: String,
    pub result_revision: u64,
    pub minimum_score: f64,
    pub include_identical: bool,
}

#[derive(Debug, Serialize, Deserialize)]
pub struct SavedGroup {
    pub id: String,
    pub file_ids: Vec<String>,
    pub minimum_score: Option<f64>,
    pub identical: bool,
}

#[derive(Debug, Serialize, Deserialize)]
pub struct SavedGroups {
    pub run_id: String,
    pub result_revision: u64,
    pub minimum_score: f64,
    pub groups: Vec<SavedGroup>,
}

pub fn group_scores(request: GroupQuery, cancel: &AtomicBool) -> Result<SavedGroups> {
    if !request.data_dir.is_absolute()
        || !request.minimum_score.is_finite()
        || !(0.05..=1.0).contains(&request.minimum_score)
        || request.result_revision == 0
    {
        bail!("Choose a saved scan and a similarity from 5% to 100%.");
    }
    let matrix =
        store::SavedMatrix::open(&request.data_dir, &request.run_id, request.result_revision)?;
    let mut files = BTreeMap::<String, Option<String>>::new();
    for file in &matrix.files {
        check_cancel(cancel)?;
        if !file.is_file {
            continue;
        }
        files.insert(
            file.id.clone(),
            file.digest.clone().filter(|_| request.include_identical),
        );
    }
    let (ids, hashes): (Vec<_>, Vec<_>) = files.into_iter().unzip();
    let ordinals: HashMap<_, _> = ids
        .iter()
        .enumerate()
        .map(|(i, id)| (id.as_str(), i))
        .collect();
    // Only earlier neighbours are needed for deterministic complete-link
    // grouping. This uses O(files + qualifying scores), not a dense N² matrix.
    let mut earlier = vec![Vec::<(usize, f64)>::new(); ids.len()];
    let mut edges = 0usize;
    matrix.visit_scores(request.minimum_score, cancel, |a,b,score| {
        if !score.is_finite() || !(-1.0..=1.0).contains(&score) { bail!("A saved similarity score is invalid."); }
        let (Some(&a),Some(&b)) = (ordinals.get(a),ordinals.get(b)) else { return Ok(()); };
        if a == b { return Ok(()); }
        edges += 1;
        if edges > 4_000_000 {
            bail!("Too many matching pairs to group at this threshold. Raise the minimum, or review individual comparisons in All Files.");
        }
        earlier[a.max(b)].push((a.min(b),score));
        Ok(())
    })?;
    let groups = partition(&ids, &hashes, earlier, cancel)?;
    Ok(SavedGroups {
        run_id: request.run_id,
        result_revision: request.result_revision,
        minimum_score: request.minimum_score,
        groups,
    })
}

/// Process the matrix from strongest to weakest. Merge clusters only once ALL
/// cross-pairs are present. Each lower cutoff extends the same merge history:
/// existing groups can grow/merge but never split or lose members. Unknown
/// measurements cannot complete a cross-pair set.
fn partition(
    ids: &[String],
    hashes: &[Option<String>],
    earlier: Vec<Vec<(usize, f64)>>,
    cancel: &AtomicBool,
) -> Result<Vec<SavedGroup>> {
    let mut parents: Vec<_> = (0..ids.len()).collect();
    let mut members = vec![Vec::new(); ids.len()];
    let mut minimums = vec![1.0f64; ids.len()];
    let mut identical = HashMap::<&str, usize>::new();
    for file in 0..ids.len() {
        check_cancel(cancel)?;
        let root = if let Some(hash) = hashes[file].as_deref() {
            *identical.entry(hash).or_insert(file)
        } else {
            file
        };
        parents[file] = root;
        members[root].push(file);
    }
    let mut edges: Vec<_> = earlier
        .into_iter()
        .enumerate()
        .flat_map(|(b, edges)| edges.into_iter().map(move |(a, score)| (a, b, score)))
        .collect();
    edges.sort_unstable_by(|a, b| {
        b.2.total_cmp(&a.2)
            .then_with(|| a.0.cmp(&b.0))
            .then_with(|| a.1.cmp(&b.1))
    });
    // Counts replace a dense matrix: a cluster pair becomes admissible exactly
    // when count == |A| * |B|. Merging combines counts for common neighbours.
    let mut links = vec![HashMap::<usize, usize>::new(); ids.len()];
    fn root(parents: &mut [usize], mut file: usize) -> usize {
        while parents[file] != file {
            parents[file] = parents[parents[file]];
            file = parents[file];
        }
        file
    }
    for (left, right, score) in edges {
        check_cancel(cancel)?;
        let a = root(&mut parents, left);
        let b = root(&mut parents, right);
        if a == b {
            continue;
        }
        let count = links[a].get(&b).copied().unwrap_or(0) + 1;
        let expected = members[a].len() * members[b].len();
        if count > expected {
            bail!("Duplicate pairs in the saved similarity matrix.");
        }
        links[a].insert(b, count);
        links[b].insert(a, count);
        if count < expected {
            continue;
        }
        let mut pending = VecDeque::from([(a, b)]);
        while let Some((a, b)) = pending.pop_front() {
            check_cancel(cancel)?;
            let mut a = root(&mut parents, a);
            let mut b = root(&mut parents, b);
            if a == b
                || links[a].get(&b).copied().unwrap_or(0) != members[a].len() * members[b].len()
            {
                continue;
            }
            // Move the smaller membership list to keep repeated merges bounded.
            if members[a].len() < members[b].len()
                || (members[a].len() == members[b].len() && a > b)
            {
                std::mem::swap(&mut a, &mut b);
            }
            parents[b] = a;
            let moved = std::mem::take(&mut members[b]);
            members[a].extend(moved);
            minimums[a] = minimums[a].min(minimums[b]).min(score);
            links[a].remove(&b);
            links[b].remove(&a);
            let mut neighbours: Vec<_> = std::mem::take(&mut links[b]).into_iter().collect();
            neighbours.sort_unstable_by_key(|&(other, _)| other);
            for (other, count) in neighbours {
                links[other].remove(&b);
                let count = links[a].get(&other).copied().unwrap_or(0) + count;
                links[a].insert(other, count);
                links[other].insert(a, count);
                if count == members[a].len() * members[other].len() {
                    pending.push_back((a, other));
                }
            }
        }
    }
    let groups = members.into_iter().zip(minimums);
    let mut output: Vec<_> = groups
        .into_iter()
        .filter(|(members, _)| members.len() > 1)
        .map(|(mut members, minimum)| {
            members.sort_unstable();
            let first = members[0];
            let identical =
                hashes[first].is_some() && members.iter().all(|&i| hashes[i] == hashes[first]);
            SavedGroup {
                id: ids[first].clone(),
                file_ids: members.into_iter().map(|i| ids[i].clone()).collect(),
                minimum_score: (!identical).then_some(minimum),
                identical,
            }
        })
        .collect();
    output.sort_by(|a, b| {
        b.file_ids
            .len()
            .cmp(&a.file_ids.len())
            .then_with(|| {
                b.minimum_score
                    .unwrap_or(1.0)
                    .total_cmp(&a.minimum_score.unwrap_or(1.0))
            })
            .then_with(|| a.id.cmp(&b.id))
    });
    Ok(output)
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn groups_require_every_pair_and_preserve_exact_evidence() {
        let ids = ["a", "b", "c", "d", "e", "f"].map(str::to_owned);
        let hashes = vec![
            None,
            None,
            None,
            Some("same".into()),
            Some("same".into()),
            None,
        ];
        let groups = partition(
            &ids,
            &hashes,
            vec![
                vec![],
                vec![(0, 0.96345)],
                vec![(1, 0.96)],
                vec![],
                vec![],
                vec![],
            ],
            &AtomicBool::new(false),
        )
        .unwrap();
        assert_eq!(groups.len(), 2);
        assert!(groups
            .iter()
            .any(|g| g.identical && g.file_ids == ["d", "e"]));
        assert!(groups
            .iter()
            .any(|g| g.minimum_score == Some(0.96345) && g.file_ids == ["a", "b"]));
        assert!(!groups.iter().any(|g| g.file_ids.contains(&"c".into())));
    }
    #[test]
    fn grouping_cancels_without_partial_output() {
        assert!(partition(&["a".into()], &[None], vec![vec![]], &AtomicBool::new(true)).is_err());
    }

    #[test]
    fn lowering_threshold_only_merges_and_every_pair_still_qualifies() {
        // Reproducible mixed matrices, including missing measurements, ties
        // and a verified identical pair. Each cutoff is queried independently.
        for seed in 1..=24 {
            let ids: Vec<_> = (0..14).map(|i| format!("file-{i:02}")).collect();
            let mut hashes = vec![None; ids.len()];
            hashes[2] = Some("same".into());
            hashes[8] = Some("same".into());
            let mut random = seed as u64;
            let mut scores = BTreeMap::new();
            for b in 0..ids.len() {
                for a in 0..b {
                    random = random.wrapping_mul(6364136223846793005).wrapping_add(1);
                    if random % 9 != 0 {
                        scores.insert((a, b), (5 + random % 96) as f64 / 100.0);
                    }
                }
            }
            let mut previous: Vec<SavedGroup> = vec![];
            for threshold in [1.0, 0.95, 0.9, 0.87, 0.75, 0.5, 0.05] {
                let mut earlier = vec![vec![]; ids.len()];
                for (&(a, b), &score) in &scores {
                    if score >= threshold {
                        earlier[b].push((a, score));
                    }
                }
                let groups = partition(&ids, &hashes, earlier, &AtomicBool::new(false)).unwrap();
                for old in &previous {
                    assert!(
                        groups
                            .iter()
                            .any(|new| old.file_ids.iter().all(|f| new.file_ids.contains(f))),
                        "Lower thresholds must preserve the earlier groups"
                    );
                }
                for group in &groups {
                    let files: Vec<_> = group
                        .file_ids
                        .iter()
                        .map(|id| ids.iter().position(|f| f == id).unwrap())
                        .collect();
                    for (index, &b) in files.iter().enumerate() {
                        for &a in &files[..index] {
                            assert!(
                                hashes[a].is_some() && hashes[a] == hashes[b]
                                    || scores
                                        .get(&(a.min(b), a.max(b)))
                                        .is_some_and(|s| *s >= threshold)
                            );
                        }
                    }
                }
                previous = groups;
            }
        }
    }
}
