// FLOW — application de lancement : choisir un projet, puis ouvrir FLOW (Claude × psmux) dedans.
// Compilé par FLOW.ps1 -InstallShortcut (csc du .NET Framework, C# 5) → FLOW.exe à la racine du dossier FLOW.
//   FLOW.exe                    fenêtre de choix du projet
//   FLOW.exe C:\chemin\projet   ouvre directement FLOW sur ce projet
//   FLOW.exe --no-project       ouvre FLOW sans projet (dossiers définis dans les profils)
using System;
using System.Collections;
using System.Collections.Generic;
using System.Diagnostics;
using System.Drawing;
using System.IO;
using System.Linq;
using System.Runtime.InteropServices;
using System.Text.RegularExpressions;
using System.Web.Script.Serialization;
using System.Windows.Forms;

[assembly: System.Reflection.AssemblyTitle("FLOW")]
[assembly: System.Reflection.AssemblyProduct("FLOW")]
[assembly: System.Reflection.AssemblyDescription("FLOW — Claude × psmux")]

namespace Flow
{
    class Project
    {
        public string Name;
        public string Dir;
        public DateTime? Last;
        public bool Git;
        public bool Running;
    }

    static class Store
    {
        // config\projects.json : { "recent": [ { "path": "...", "last": "2026-11-13T18:00:00" } ] } — lu aussi par FLOW.ps1
        static string FileOf(string root) { return Path.Combine(root, "config", "projects.json"); }

        public static List<KeyValuePair<string, DateTime>> Recent(string root)
        {
            var list = new List<KeyValuePair<string, DateTime>>();
            try
            {
                var f = FileOf(root);
                if (!File.Exists(f)) return list;
                var js = new JavaScriptSerializer();
                var d = js.DeserializeObject(File.ReadAllText(f)) as Dictionary<string, object>;
                if (d == null || !d.ContainsKey("recent")) return list;
                var arr = d["recent"] as object[];
                if (arr == null) return list;
                foreach (var o in arr)
                {
                    var x = o as Dictionary<string, object>;
                    if (x == null || !x.ContainsKey("path")) continue;
                    DateTime t = DateTime.MinValue;
                    if (x.ContainsKey("last") && x["last"] != null) DateTime.TryParse(x["last"].ToString(), out t);
                    list.Add(new KeyValuePair<string, DateTime>(x["path"].ToString(), t));
                }
            }
            catch { }
            return list;
        }

        public static void Touch(string root, string dir)
        {
            try
            {
                var list = Recent(root).Where(k => !string.Equals(k.Key.TrimEnd('\\'), dir.TrimEnd('\\'), StringComparison.OrdinalIgnoreCase)).ToList();
                list.Insert(0, new KeyValuePair<string, DateTime>(dir, DateTime.Now));
                var arr = list.Take(30).Select(k => new Dictionary<string, object> { { "path", k.Key }, { "last", k.Value.ToString("s") } }).ToArray();
                var js = new JavaScriptSerializer();
                var json = js.Serialize(new Dictionary<string, object> { { "recent", arr } });
                Directory.CreateDirectory(Path.GetDirectoryName(FileOf(root)));
                File.WriteAllText(FileOf(root), json, new System.Text.UTF8Encoding(false));
            }
            catch { }
        }
    }

    static class Launcher
    {
        public static string Slug(string name)
        {
            var s = name.ToLowerInvariant().Normalize(System.Text.NormalizationForm.FormD);
            s = Regex.Replace(s, @"\p{Mn}", "");
            s = Regex.Replace(s, "[^a-z0-9]+", "-").Trim('-');
            return s.Length > 0 ? s : "projet";
        }

        static string Q(string s) { return "\"" + s.TrimEnd('\\') + "\""; }

        static bool TryStart(string exe, string args)
        {
            try
            {
                var psi = new ProcessStartInfo(exe, args) { UseShellExecute = true };
                Process.Start(psi);
                return true;
            }
            catch { return false; }
        }

        // pwsh.exe : dans le PATH, sinon à son emplacement habituel (le PATH d'une fenêtre ouverte avant l'installation ne le contient pas encore) ; null s'il n'existe pas
        public static string FindPwsh()
        {
            foreach (var dir in (Environment.GetEnvironmentVariable("PATH") ?? "").Split(';'))
            {
                try
                {
                    var d = dir.Trim().Trim('"');
                    if (d.Length == 0) continue;
                    var p = Path.Combine(d, "pwsh.exe");
                    if (File.Exists(p)) return p;
                }
                catch { }
            }
            var pf = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.ProgramFiles), @"PowerShell\7\pwsh.exe");
            if (File.Exists(pf)) return pf;
            var store = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), @"Microsoft\WindowsApps\pwsh.exe");   // installation du Store
            return File.Exists(store) ? store : null;
        }

        // ouvre FLOW dans une nouvelle fenêtre de terminal ; dir = null : sans projet
        public static bool Run(string root, string dir)
        {
            // PowerShell 7 d'abord : sans lui, Windows Terminal s'ouvrirait sur une erreur obscure au lieu d'un message clair
            var pwsh = FindPwsh();
            if (pwsh == null)
            {
                MessageBox.Show("PowerShell 7 est introuvable : FLOW ne peut pas démarrer.\n\nDouble-clique sur install.cmd (dans le dossier FLOW) : il l'installe, avec le reste.",
                    "FLOW", MessageBoxButtons.OK, MessageBoxIcon.Error);
                return false;
            }
            var script = Path.Combine(root, "FLOW.ps1");
            var title = dir == null ? "FLOW" : "FLOW · " + Path.GetFileName(dir.TrimEnd('\\'));
            var ps = "-NoProfile -ExecutionPolicy Bypass -File " + Q(script) + (dir == null ? "" : " -Project " + Q(dir));
            // wt.exe est résolu au lancement (alias d'application) : survit aux mises à jour de Windows Terminal
            var wtAlias = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), @"Microsoft\WindowsApps\wt.exe");
            var wtArgs = "-w new --title " + Q(title) + " " + Q(pwsh) + " " + ps;
            if (TryStart("wt.exe", wtArgs)) return true;
            if (File.Exists(wtAlias) && TryStart(wtAlias, wtArgs)) return true;
            if (TryStart(pwsh, ps)) return true;
            MessageBox.Show("FLOW n'a pas pu ouvrir PowerShell 7.\n\nDouble-clique sur install.cmd (dans le dossier FLOW) pour vérifier l'installation.",
                "FLOW", MessageBoxButtons.OK, MessageBoxIcon.Error);
            return false;
        }

        // noms des sessions psmux FLOW en cours (serveur « flow »)
        public static HashSet<string> Sessions()
        {
            var set = new HashSet<string>(StringComparer.OrdinalIgnoreCase);
            try
            {
                var psi = new ProcessStartInfo("psmux", "-L flow ls -F #{session_name}")
                {
                    UseShellExecute = false, RedirectStandardOutput = true, RedirectStandardError = true, CreateNoWindow = true
                };
                using (var p = Process.Start(psi))
                {
                    var outTxt = p.StandardOutput.ReadToEnd();
                    p.WaitForExit(1500);
                    foreach (var l in outTxt.Split('\n')) { var t = l.Trim(); if (t.Length > 0) set.Add(t); }
                }
            }
            catch { }
            return set;
        }
    }

    static class Program
    {
        [DllImport("user32.dll")] static extern bool SetProcessDPIAware();

        [STAThread]
        static int Main(string[] args)
        {
            try { SetProcessDPIAware(); } catch { }
            Application.EnableVisualStyles();
            Application.SetCompatibleTextRenderingDefault(false);
            var root = AppDomain.CurrentDomain.BaseDirectory.TrimEnd('\\');
            if (!File.Exists(Path.Combine(root, "FLOW.ps1")))
            {
                MessageBox.Show("FLOW.ps1 est introuvable à côté de FLOW.exe :\n" + root, "FLOW", MessageBoxButtons.OK, MessageBoxIcon.Error);
                return 1;
            }
            if (args.Length > 0)
            {
                if (args[0] == "--no-project") return Launcher.Run(root, null) ? 0 : 1;
                string d = null;
                try { d = Path.GetFullPath(Environment.ExpandEnvironmentVariables(args[0])); } catch { }
                if (d != null && Directory.Exists(d))
                {
                    Store.Touch(root, d);
                    return Launcher.Run(root, d) ? 0 : 1;
                }
                MessageBox.Show("Dossier introuvable :\n" + args[0], "FLOW", MessageBoxButtons.OK, MessageBoxIcon.Warning);
            }
            Application.Run(new PickerForm(root));
            return 0;
        }
    }

    class PickerForm : Form
    {
        static readonly Color Bg = Color.FromArgb(22, 22, 30);
        static readonly Color Panel = Color.FromArgb(32, 32, 44);
        static readonly Color Fg = Color.FromArgb(230, 230, 240);
        static readonly Color Dim = Color.FromArgb(140, 140, 160);
        static readonly Color Accent = Color.FromArgb(168, 112, 255);
        static readonly Color Live = Color.FromArgb(96, 232, 196);

        readonly string root;
        readonly string projectsRoot;
        List<Project> all = new List<Project>();
        readonly TextBox search = new TextBox();
        readonly ListView list = new ListView();
        readonly Label status = new Label();

        [DllImport("user32.dll", CharSet = CharSet.Unicode)]
        static extern IntPtr SendMessage(IntPtr h, int msg, IntPtr w, string l);

        public PickerForm(string root)
        {
            this.root = root;
            projectsRoot = Path.GetDirectoryName(root);
            Text = "FLOW — choisir un projet";
            try { Icon = Icon.ExtractAssociatedIcon(Application.ExecutablePath); } catch { }
            BackColor = Bg; ForeColor = Fg;
            Font = new Font("Segoe UI", 10f);
            AutoScaleMode = AutoScaleMode.Dpi;
            StartPosition = FormStartPosition.CenterScreen;
            ClientSize = new Size(860, 560);
            MinimumSize = new Size(620, 420);
            Padding = new Padding(20, 16, 20, 16);
            KeyPreview = true;

            // — liste —
            list.View = View.Details;
            list.FullRowSelect = true;
            list.MultiSelect = false;
            list.HideSelection = false;
            list.BorderStyle = BorderStyle.None;
            list.BackColor = Panel; list.ForeColor = Fg;
            list.HeaderStyle = ColumnHeaderStyle.Nonclickable;
            list.Columns.Add("Projet", 230);
            list.Columns.Add("Dossier", 360);
            list.Columns.Add("Dernière ouverture", 150);
            list.Columns.Add("", 70);
            list.Dock = DockStyle.Fill;
            list.DoubleClick += delegate { OpenSelected(); };
            list.Resize += delegate { FitColumns(); };
            var small = new ImageList { ImageSize = new Size(1, 28) };   // hauteur de ligne confortable
            list.SmallImageList = small;
            Controls.Add(list);

            // — recherche —
            var searchWrap = new Panel { Dock = DockStyle.Top, Height = 46, Padding = new Padding(0, 6, 0, 10) };
            search.Dock = DockStyle.Fill;
            search.BackColor = Panel; search.ForeColor = Fg;
            search.BorderStyle = BorderStyle.FixedSingle;
            search.Font = new Font("Segoe UI", 11f);
            search.TextChanged += delegate { Fill(); };
            search.KeyDown += (s, e) =>
            {
                if (e.KeyCode == Keys.Down && list.Items.Count > 0) { list.Focus(); Select(Math.Min(1, list.Items.Count - 1)); e.Handled = true; }
            };
            searchWrap.Controls.Add(search);
            Controls.Add(searchWrap);

            // — en-tête —
            var head = new Panel { Dock = DockStyle.Top, Height = 74 };
            var title = new Label { Text = "◆ FLOW", AutoSize = true, Font = new Font("Segoe UI Semibold", 22f), ForeColor = Accent, Location = new Point(0, 0) };
            var sub = new Label
            {
                Text = "Choisis le projet dans lequel Claude va travailler", AutoSize = true, ForeColor = Dim, Location = new Point(3, 46)
            };
            head.Controls.Add(title); head.Controls.Add(sub);
            Controls.Add(head);

            // — boutons —
            var bar = new FlowLayoutPanel
            {
                Dock = DockStyle.Bottom, AutoSize = true, FlowDirection = FlowDirection.RightToLeft,
                Padding = new Padding(0, 12, 0, 0), WrapContents = false
            };
            var open = Btn("Ouvrir", true); open.Click += delegate { OpenSelected(); };
            var none = Btn("Sans projet", false); none.Click += delegate { if (Launcher.Run(root, null)) Close(); };
            var browse = Btn("Parcourir…", false); browse.Click += delegate { Browse(); };
            var create = Btn("Nouveau projet…", false); create.Click += delegate { CreateProject(); };
            var explore = Btn("Afficher le dossier", false); explore.Click += delegate { var p = Current(); if (p != null) Process.Start("explorer.exe", "\"" + p.Dir + "\""); };
            bar.Controls.AddRange(new Control[] { open, none, browse, create, explore });
            Controls.Add(bar);

            status.Dock = DockStyle.Bottom; status.Height = 26; status.ForeColor = Dim;
            status.TextAlign = ContentAlignment.BottomLeft;
            status.Text = "Entrée : ouvrir · Échap : quitter · tape pour filtrer · ● une session FLOW tourne déjà sur ce projet";
            Controls.Add(status);

            AcceptButton = open;
            Load += delegate { SendMessage(search.Handle, 0x1501, (IntPtr)1, "Rechercher un projet…"); Reload(null); search.Focus(); };
            KeyDown += (s, e) => { if (e.KeyCode == Keys.Escape) Close(); };
        }

        Button Btn(string text, bool primary)
        {
            var b = new Button
            {
                Text = text, AutoSize = true, FlatStyle = FlatStyle.Flat, Padding = new Padding(10, 4, 10, 4),
                Margin = new Padding(8, 0, 0, 0), BackColor = primary ? Accent : Panel, ForeColor = primary ? Color.White : Fg,
                Font = new Font("Segoe UI", 10f, primary ? FontStyle.Bold : FontStyle.Regular)
            };
            b.FlatAppearance.BorderColor = primary ? Accent : Color.FromArgb(60, 60, 80);
            return b;
        }

        void FitColumns()
        {
            if (list.Columns.Count < 4) return;
            int w = list.ClientSize.Width - list.Columns[0].Width - list.Columns[2].Width - list.Columns[3].Width - 4;
            if (w > 120) list.Columns[1].Width = w;
        }

        void Reload(string selectDir)
        {
            var map = new Dictionary<string, Project>(StringComparer.OrdinalIgnoreCase);
            var sessions = Launcher.Sessions();
            Func<string, Project> make = d =>
            {
                var n = Path.GetFileName(d.TrimEnd('\\'));
                var slug = "--" + Launcher.Slug(n);
                return new Project
                {
                    Name = n, Dir = d, Git = Directory.Exists(Path.Combine(d, ".git")),
                    Running = sessions.Any(s => s.EndsWith(slug, StringComparison.OrdinalIgnoreCase))
                };
            };
            try
            {
                foreach (var d in Directory.GetDirectories(projectsRoot))
                {
                    var name = Path.GetFileName(d);
                    if (string.Equals(d.TrimEnd('\\'), root, StringComparison.OrdinalIgnoreCase)) continue;   // FLOW lui-même
                    if (name.StartsWith(".")) continue;
                    // <projet>-flow : copies de travail du mode Équipe, pas un projet
                    if (name.EndsWith("-flow", StringComparison.OrdinalIgnoreCase) && Directory.Exists(Path.Combine(projectsRoot, name.Substring(0, name.Length - 5)))) continue;
                    map[d.TrimEnd('\\')] = make(d);
                }
            }
            catch { }
            foreach (var r in Store.Recent(root))
            {
                var d = r.Key.TrimEnd('\\');
                if (!Directory.Exists(d)) continue;
                Project p;
                if (!map.TryGetValue(d, out p)) { p = make(d); map[d] = p; }
                if (r.Value > DateTime.MinValue) p.Last = r.Value;
            }
            all = map.Values
                .OrderByDescending(p => p.Last.HasValue)
                .ThenByDescending(p => p.Last ?? DateTime.MinValue)
                .ThenBy(p => p.Name, StringComparer.OrdinalIgnoreCase)
                .ToList();
            Fill();
            if (selectDir != null)
                for (int i = 0; i < list.Items.Count; i++)
                    if (string.Equals(((Project)list.Items[i].Tag).Dir, selectDir, StringComparison.OrdinalIgnoreCase)) { Select(i); break; }
        }

        void Fill()
        {
            var q = search.Text.Trim();
            list.BeginUpdate();
            list.Items.Clear();
            foreach (var p in all)
            {
                if (q.Length > 0 && p.Name.IndexOf(q, StringComparison.OrdinalIgnoreCase) < 0 && p.Dir.IndexOf(q, StringComparison.OrdinalIgnoreCase) < 0) continue;
                var it = new ListViewItem((p.Running ? "● " : "    ") + p.Name) { Tag = p };
                it.SubItems.Add(p.Dir);
                it.SubItems.Add(p.Last.HasValue ? Ago(p.Last.Value) : "—");
                it.SubItems.Add(p.Git ? "git" : "");
                it.UseItemStyleForSubItems = false;
                it.ForeColor = p.Running ? Live : Fg;
                it.SubItems[1].ForeColor = Dim; it.SubItems[2].ForeColor = Dim; it.SubItems[3].ForeColor = Accent;
                foreach (ListViewItem.ListViewSubItem si in it.SubItems) si.BackColor = Panel;
                list.Items.Add(it);
            }
            list.EndUpdate();
            if (list.Items.Count > 0) Select(0);
            FitColumns();
        }

        static string Ago(DateTime t)
        {
            var d = DateTime.Now - t;
            if (d.TotalMinutes < 1) return "à l'instant";
            if (d.TotalHours < 1) return "il y a " + (int)d.TotalMinutes + " min";
            if (d.TotalDays < 1) return "il y a " + (int)d.TotalHours + " h";
            if (d.TotalDays < 2) return "hier";
            if (d.TotalDays < 30) return "il y a " + (int)d.TotalDays + " j";
            return t.ToString("dd/MM/yyyy");
        }

        void Select(int i)
        {
            if (i < 0 || i >= list.Items.Count) return;
            list.SelectedIndices.Clear();
            list.Items[i].Selected = true; list.Items[i].Focused = true;
            list.EnsureVisible(i);
        }

        Project Current() { return list.SelectedItems.Count > 0 ? (Project)list.SelectedItems[0].Tag : null; }

        void OpenSelected()
        {
            var p = Current();
            if (p == null) { status.Text = "Choisis un projet dans la liste (ou « Nouveau projet… »)."; return; }
            Launch(p.Dir);
        }

        void Launch(string dir)
        {
            Store.Touch(root, dir);
            if (Launcher.Run(root, dir)) Close();
        }

        void Browse()
        {
            using (var dlg = new FolderBrowserDialog { Description = "Dossier du projet", SelectedPath = projectsRoot, ShowNewFolderButton = true })
                if (dlg.ShowDialog(this) == DialogResult.OK) Launch(dlg.SelectedPath);
        }

        void CreateProject()
        {
            using (var f = new Form
            {
                Text = "Nouveau projet", FormBorderStyle = FormBorderStyle.FixedDialog, StartPosition = FormStartPosition.CenterParent,
                MinimizeBox = false, MaximizeBox = false, BackColor = Bg, ForeColor = Fg, Font = Font, ClientSize = new Size(460, 170),
                AutoScaleMode = AutoScaleMode.Dpi
            })
            {
                var lbl = new Label { Text = "Nom du projet (créé dans " + projectsRoot + ")", AutoSize = true, Location = new Point(16, 14), ForeColor = Dim };
                var tb = new TextBox { Location = new Point(18, 42), Width = 424, BackColor = Panel, ForeColor = Fg, BorderStyle = BorderStyle.FixedSingle };
                var git = new CheckBox { Text = "Initialiser un dépôt Git", Checked = true, AutoSize = true, Location = new Point(18, 78) };
                var ok = Btn("Créer et ouvrir", true); ok.Location = new Point(300, 118); ok.DialogResult = DialogResult.OK;
                var cancel = Btn("Annuler", false); cancel.Location = new Point(200, 118); cancel.DialogResult = DialogResult.Cancel;
                f.Controls.AddRange(new Control[] { lbl, tb, git, ok, cancel });
                f.AcceptButton = ok; f.CancelButton = cancel;
                if (f.ShowDialog(this) != DialogResult.OK) return;
                var name = tb.Text.Trim();
                if (name.Length == 0 || name.IndexOfAny(Path.GetInvalidFileNameChars()) >= 0)
                {
                    MessageBox.Show(this, "Nom de dossier invalide.", "FLOW", MessageBoxButtons.OK, MessageBoxIcon.Warning); return;
                }
                var dir = Path.Combine(projectsRoot, name);
                if (Directory.Exists(dir))
                {
                    if (MessageBox.Show(this, "« " + name + " » existe déjà. L'ouvrir ?", "FLOW", MessageBoxButtons.YesNo, MessageBoxIcon.Question) != DialogResult.Yes) return;
                }
                else
                {
                    try { Directory.CreateDirectory(dir); }
                    catch (Exception ex) { MessageBox.Show(this, ex.Message, "FLOW", MessageBoxButtons.OK, MessageBoxIcon.Error); return; }
                    if (git.Checked)
                    {
                        try
                        {
                            var psi = new ProcessStartInfo("git", "init -b main") { WorkingDirectory = dir, UseShellExecute = false, CreateNoWindow = true };
                            using (var p = Process.Start(psi)) p.WaitForExit(10000);
                        }
                        catch { }
                    }
                }
                Launch(dir);
            }
        }
    }
}
