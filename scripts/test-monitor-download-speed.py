import importlib.util,json,pathlib,tempfile,unittest
spec=importlib.util.spec_from_file_location("speed_monitor",pathlib.Path(__file__).with_name("monitor-download-speed.py"))
m=importlib.util.module_from_spec(spec);spec.loader.exec_module(m)
def row(second,total,pid=41):return {"version":1,"helper_pid":pid,"received_bytes":total,"sampled_uptime":second,"updated_at":1000+second}
class LiveSpeedTests(unittest.TestCase):
 def test_five_second_window_and_duplicate_snapshots(self):
  rates=m.LiveRates()
  for t in range(11):
   total=t*1_000_000 if t<=5 else 5_000_000+(t-5)*2_000_000
   result=rates.sample(row(t,total),1000+t)
   self.assertEqual(rates.sample(row(t,total),1000+t),result)
  self.assertEqual(result,(2_000_000,2_000_000))
 def test_restart_stale_sleep_and_backward_counters(self):
  rates=m.LiveRates();rates.sample(row(0,9_000_000),1000)
  self.assertEqual(rates.sample(row(1,10_000_000),1001),(1_000_000,1_000_000))
  self.assertEqual(rates.sample(row(2,0,42),1002),(0,None))
  self.assertEqual(rates.sample(row(3,1_000_000,42),1003),(1_000_000,1_000_000))
  self.assertIsNone(rates.sample(row(3,1_000_000,42),1010))
  self.assertEqual(rates.sample(row(20,1_000_000,42),1020),(0,None))
  self.assertEqual(rates.sample(row(21,0,42),1021),(0,None))
 def test_delayed_publication_keeps_history_and_partial_windows_are_marked(self):
  rates=m.LiveRates();rates.sample(row(0,0),1000)
  self.assertFalse(rates.window_ready)
  rates.sample(row(1,1_000_000),1001)
  self.assertEqual(rates.sample(row(1,1_000_000),1004.9),(1_000_000,1_000_000))
  self.assertEqual(rates.sample(row(4.8,4_800_000),1004.9),(1_000_000,1_000_000))
  self.assertFalse(rates.window_ready)
  current,average=rates.sample(row(5.9,5_900_000),1005.9)
  self.assertAlmostEqual(current,1_000_000)
  self.assertAlmostEqual(average,1_000_000)
  self.assertTrue(rates.window_ready)
  self.assertIsNone(rates.sample(row(5.9,5_900_000),1012))
  self.assertFalse(rates.window_ready)
 def test_invalid_or_extra_fields_never_enter_output(self):
  rates=m.LiveRates()
  for extra in [{"filename":"generated-private.bin"},{"helper_pid":True},{"received_bytes":-1},{"sampled_uptime":float("nan")},{"version":2}]:
   value=row(0,0);value.update(extra);self.assertIsNone(rates.sample(value,1000))
  self.assertIsNone(rates.sample(None,1000))
 def test_private_bounded_regular_file_only(self):
  with tempfile.TemporaryDirectory() as d:
   p=pathlib.Path(d)/"generated-live.json";value=row(0,0);p.write_text(json.dumps(value));self.assertEqual(m.read_live(p),value)
   link=pathlib.Path(d)/"generated-link";link.symlink_to(p);self.assertIsNone(m.read_live(link))
   p.write_bytes(b" "*513);self.assertIsNone(m.read_live(p))
   p.write_text("{partial");self.assertIsNone(m.read_live(p))
if __name__=="__main__":unittest.main()
