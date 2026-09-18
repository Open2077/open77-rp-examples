-- rp_jobs -- shared configuration (loaded on both runtimes).
--
-- Everything an owner may want to move or retune lives here: the job table,
-- the grade ladder, the salaries, the payroll clock, the society seed and the
-- employment agency's position. Nothing in this file touches a native.

RpJobsConfig = {}

-- Grade ladder, 0..3. `label` is what players read; `level` is what is stored.
RpJobsConfig.Grades = {
    [0] = { level = 0, label = "recruit" },
    [1] = { level = 1, label = "employee" },
    [2] = { level = 2, label = "senior" },
    [3] = { level = 3, label = "boss" },
}
RpJobsConfig.BossGrade = 3

-- The twelve jobs. Order matters for /jobs and the agency menu.
--   name        : the key every export, event, society and SQL row uses
--   label       : display name
--   color       : nameplate / tag colour while on duty (#RRGGBB)
--   civil       : true = anyone may join freely at the agency; false = hired by a boss or set by an admin
--   reserved    : true = nobody may hold it yet (kept for a later resource)
--   salary      : eddies per payroll, indexed by grade 0..3
RpJobsConfig.Jobs = {
    { name = "ncpd",        label = "NCPD",           color = "#2F7BFF", civil = false, description = "Badge, cuffs and the law of Night City.",         salary = { [0] = 300, [1] = 450, [2] = 600, [3] = 800 } },
    { name = "trauma",      label = "Trauma Team",    color = "#FF3B3B", civil = false, description = "Platinum coverage, AV drops and defib paddles.",   salary = { [0] = 300, [1] = 450, [2] = 600, [3] = 800 } },
    { name = "delamain",    label = "Delamain",       color = "#FFD23F", civil = true,  description = "The city's most polite cab company.",             salary = { [0] = 200, [1] = 300, [2] = 400, [3] = 550 } },
    { name = "mecano",      label = "Mechanic",       color = "#FF8C1A", civil = true,  description = "Wrenches, tow trucks and chrome paint.",           salary = { [0] = 200, [1] = 300, [2] = 400, [3] = 550 } },
    { name = "ripper",      label = "Ripperdoc",      color = "#C93CFF", civil = false, description = "Chrome in, eddies out. No questions.",             salary = { [0] = 250, [1] = 400, [2] = 550, [3] = 750 } },
    { name = "nomade",      label = "Nomad",          color = "#C9A24D", civil = true,  description = "Badlands convoys and long hauls.",                 salary = { [0] = 180, [1] = 260, [2] = 360, [3] = 500 } },
    { name = "ferrailleur", label = "Scrapper",       color = "#9AA0A6", civil = true,  description = "Scrap, components and the odd wreck.",             salary = { [0] = 150, [1] = 220, [2] = 300, [3] = 420 } },
    { name = "barman",      label = "Bartender",      color = "#FF4FA3", civil = true,  description = "Pours the drinks, hears the gossip.",              salary = { [0] = 150, [1] = 220, [2] = 300, [3] = 420 } },
    { name = "fixer",       label = "Fixer",          color = "#00E5FF", civil = false, description = "Gigs, contacts and a cut of everything.",         salary = { [0] = 250, [1] = 400, [2] = 550, [3] = 750 } },
    { name = "netrunner",   label = "Netrunner",      color = "#3CFF8F", civil = false, description = "ICE, daemons and other people's data.",           salary = { [0] = 250, [1] = 400, [2] = 550, [3] = 750 } },
    { name = "vigile",      label = "Security guard", color = "#B0C4DE", civil = true,  description = "Doors, corridors and a stun baton.",              salary = { [0] = 180, [1] = 260, [2] = 360, [3] = 500 } },
    { name = "gang",        label = "Gang",           color = "#7A1F1F", civil = false, reserved = true, description = "Reserved for a later resource.", salary = { [0] = 0, [1] = 0, [2] = 0, [3] = 0 } },
}

-- Legacy names the phase-0 resources still ask about (hasJob / setJob accept them).
RpJobsConfig.Aliases = {
    police  = "ncpd",
    medecin = "trauma",
    taxi    = "delamain",
}

-- Payroll: every on-duty employee is paid the salary of their grade, in cash,
-- from the job's society (rp_bank), every PayrollIntervalMs.
RpJobsConfig.PayrollIntervalMs = 10 * 60 * 1000

-- The first time a job gets its first boss (through /setjob), the society is
-- seeded with this amount so payroll has something to pay from.
RpJobsConfig.SocietyStartingFund = 50000

-- A boss must stand within this many metres of the person they hire (/embaucher and ALT+click).
RpJobsConfig.HireDistance = 5.0

-- The employment agency: a ring, a map pin and an E prompt on The Gallery, the elevated
-- walkway at the north end of Kabuki Market (walked point -1173.12, 2087.44, 11.94; 83 m
-- north-east of the freeroam spawn, Market Centre -1191.30, 2006.88, 7.82). z is the walked
-- height: stand on the spot, /pos, and paste the ground height if the ring is not visible.
RpJobsConfig.Agency = {
    position = { x = -1173.12, y = 2087.44, z = 11.94 },
    radius = 1.5,
    promptDistance = 3.0,
    maxDistance = 80.0,
    color = "#22D8E2",
    label = "Employment agency - Kabuki Gallery",
    description = "Press E to browse the open positions.",
    -- /agence works within this many metres of the agency (ground distance). 0 = anywhere.
    reach = 12.0,
    -- The job board: a data terminal spawned by the server 1.2 m behind the ring
    -- (Open77.props.create, removed on stop; a refusal only logs). false = no prop.
    prop = {
        model = "electronics.monitor.device",
        position = { x = -1172.30, y = 2088.30, z = 11.94 },
        yaw = 225.0,
    },
}

-- How far away an on-duty nameplate tag stays readable (metres).
RpJobsConfig.NameplateMaxDistance = 40

-- Colour of the resource's chat lines.
RpJobsConfig.ChatAuthor = "NC Jobs"
RpJobsConfig.ChatColor = { 34, 216, 226 }
