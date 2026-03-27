try { require('dotenv').config(); } catch(_) {}
const express = require('express');
const path = require('path');
const { createClient } = require('@supabase/supabase-js');

const app = express();
const PORT = process.env.PORT || 3000;

// Supabase service role client (server-side only)
let supabaseAdmin;
if (process.env.SUPABASE_URL && process.env.SUPABASE_SERVICE_ROLE_KEY) {
  supabaseAdmin = createClient(
    process.env.SUPABASE_URL,
    process.env.SUPABASE_SERVICE_ROLE_KEY,
    { db: { schema: 'courssem' } }
  );
} else {
  console.error('WARNING: SUPABASE_URL or SUPABASE_SERVICE_ROLE_KEY not set. API endpoints will not work.');
}

app.use(express.json());

// Helper: verify auth token and return user
async function getAuthUser(req) {
  const token = req.headers.authorization?.replace('Bearer ', '');
  if (!token) return null;
  const { data: { user }, error } = await supabaseAdmin.auth.getUser(token);
  return error ? null : user;
}

// Inject Supabase config into pages via a runtime JS endpoint
app.get('/js/config.js', (req, res) => {
  res.type('application/javascript');
  res.send(`
    window.__SEM_CONFIG = {
      SUPABASE_URL: "${process.env.SUPABASE_URL || ''}",
      SUPABASE_ANON_KEY: "${process.env.SUPABASE_ANON_KEY || ''}",
      PROF_EMAILS: "${process.env.PROF_EMAILS || ''}".split(",").map(e => e.trim().toLowerCase())
    };
  `);
});

// ===================== API: Group Registration =====================

app.post('/api/register-group', async (req, res) => {
  try {
    const { groupName, password, members, subject, groupClass } = req.body;

    // Validation
    if (!groupName || !password || !members || !Array.isArray(members) || members.length === 0) {
      return res.status(400).json({ error: 'Nom du groupe, mot de passe et au moins 1 membre requis.' });
    }
    if (/\s/.test(groupName)) {
      return res.status(400).json({ error: 'Le nom du groupe ne doit pas contenir d\'espaces.' });
    }
    if (password.length < 6) {
      return res.status(400).json({ error: 'Le mot de passe doit faire au moins 6 caracteres.' });
    }
    for (const m of members) {
      if (!m.firstName || !m.lastName || !m.email) {
        return res.status(400).json({ error: 'Chaque membre doit avoir un nom, prenom et email.' });
      }
    }

    // Check group name uniqueness
    const { data: existing } = await supabaseAdmin.from('sem_groups').select('id').eq('group_name', groupName).maybeSingle();
    if (existing) {
      return res.status(400).json({ error: 'Ce nom de groupe existe deja.' });
    }

    // Create the group (created_by will be updated after first user creation)
    const { data: group, error: groupErr } = await supabaseAdmin.from('sem_groups').insert({
      group_name: groupName
    }).select().single();
    if (groupErr) throw groupErr;

    const createdUsers = [];
    try {
      // Create auth accounts for each member
      for (const m of members) {
        const fullName = `${m.firstName} ${m.lastName}`;
        const { data: userData, error: userErr } = await supabaseAdmin.auth.admin.createUser({
          email: m.email,
          password: password,
          email_confirm: true,
          user_metadata: {
            full_name: fullName,
            first_name: m.firstName,
            last_name: m.lastName,
            group_id: group.id,
            role: 'student'
          }
        });
        if (userErr) throw new Error(`Erreur pour ${m.email}: ${userErr.message}`);
        createdUsers.push(userData.user);
      }

      // Set created_by to first member
      await supabaseAdmin.from('sem_groups').update({ created_by: createdUsers[0].id }).eq('id', group.id);

      // Create the group exercise
      await supabaseAdmin.from('sem_exercises').insert({
        group_id: group.id,
        title: 'Mon exercice SEM',
        data: { ...(subject ? { 'group-subject': subject } : {}), ...(groupClass ? { 'group-class': groupClass } : {}) }
      });

      res.json({ success: true, groupId: group.id, memberCount: createdUsers.length });
    } catch (innerErr) {
      // Rollback: delete created users and group
      for (const u of createdUsers) {
        try { await supabaseAdmin.auth.admin.deleteUser(u.id); } catch (_) {}
      }
      try { await supabaseAdmin.from('sem_groups').delete().eq('id', group.id); } catch (_) {}
      throw innerErr;
    }
  } catch (err) {
    console.error('register-group error:', err);
    res.status(500).json({ error: err.message || 'Erreur serveur.' });
  }
});

// ===================== API: Get Group Members =====================

app.get('/api/group-members', async (req, res) => {
  try {
    const user = await getAuthUser(req);
    if (!user) return res.status(401).json({ error: 'Non authentifie.' });

    // Get user's group_id
    const { data: profile } = await supabaseAdmin.from('sem_profiles').select('group_id').eq('id', user.id).single();
    if (!profile?.group_id) return res.status(404).json({ error: 'Aucun groupe trouve.' });

    // Get group info
    const { data: group } = await supabaseAdmin.from('sem_groups').select('id, group_name, created_by').eq('id', profile.group_id).single();

    // Get all members
    const { data: members } = await supabaseAdmin.from('sem_profiles').select('id, first_name, last_name, email').eq('group_id', profile.group_id);

    res.json({ group, members: members || [] });
  } catch (err) {
    console.error('group-members error:', err);
    res.status(500).json({ error: err.message || 'Erreur serveur.' });
  }
});

// ===================== API: Add Member =====================

app.post('/api/add-member', async (req, res) => {
  try {
    const user = await getAuthUser(req);
    if (!user) return res.status(401).json({ error: 'Non authentifie.' });

    const { firstName, lastName, email, password } = req.body;
    if (!firstName || !lastName || !email || !password) {
      return res.status(400).json({ error: 'Tous les champs sont requis.' });
    }

    // Verify user is group creator
    const { data: profile } = await supabaseAdmin.from('sem_profiles').select('group_id').eq('id', user.id).single();
    if (!profile?.group_id) return res.status(404).json({ error: 'Aucun groupe trouve.' });

    const { data: group } = await supabaseAdmin.from('sem_groups').select('created_by').eq('id', profile.group_id).single();
    if (group.created_by !== user.id) {
      return res.status(403).json({ error: 'Seul le createur du groupe peut ajouter des membres.' });
    }

    // Create auth user
    const fullName = `${firstName} ${lastName}`;
    const { data: userData, error: userErr } = await supabaseAdmin.auth.admin.createUser({
      email,
      password,
      email_confirm: true,
      user_metadata: {
        full_name: fullName,
        first_name: firstName,
        last_name: lastName,
        group_id: profile.group_id,
        role: 'student'
      }
    });
    if (userErr) return res.status(400).json({ error: userErr.message });

    res.json({ success: true, memberId: userData.user.id });
  } catch (err) {
    console.error('add-member error:', err);
    res.status(500).json({ error: err.message || 'Erreur serveur.' });
  }
});

// ===================== API: Remove Member =====================

app.delete('/api/remove-member', async (req, res) => {
  try {
    const user = await getAuthUser(req);
    if (!user) return res.status(401).json({ error: 'Non authentifie.' });

    const { memberId } = req.body;
    if (!memberId) return res.status(400).json({ error: 'memberId requis.' });

    // Verify user is group creator
    const { data: profile } = await supabaseAdmin.from('sem_profiles').select('group_id').eq('id', user.id).single();
    if (!profile?.group_id) return res.status(404).json({ error: 'Aucun groupe trouve.' });

    const { data: group } = await supabaseAdmin.from('sem_groups').select('created_by').eq('id', profile.group_id).single();
    if (group.created_by !== user.id) {
      return res.status(403).json({ error: 'Seul le createur du groupe peut supprimer des membres.' });
    }
    if (memberId === user.id) {
      return res.status(400).json({ error: 'Vous ne pouvez pas vous supprimer vous-meme.' });
    }

    // Verify member belongs to same group
    const { data: memberProfile } = await supabaseAdmin.from('sem_profiles').select('group_id').eq('id', memberId).single();
    if (!memberProfile || memberProfile.group_id !== profile.group_id) {
      return res.status(400).json({ error: 'Ce membre n\'appartient pas a votre groupe.' });
    }

    // Delete auth user (cascades to sem_profiles)
    const { error: delErr } = await supabaseAdmin.auth.admin.deleteUser(memberId);
    if (delErr) return res.status(400).json({ error: delErr.message });

    res.json({ success: true });
  } catch (err) {
    console.error('remove-member error:', err);
    res.status(500).json({ error: err.message || 'Erreur serveur.' });
  }
});

// Serve static files
app.use(express.static(path.join(__dirname, 'public')));

// SPA fallback — all routes serve index.html
app.get('*', (req, res) => {
  const file = req.path === '/prof' ? 'prof.html'
    : req.path === '/app' ? 'app.html'
    : 'index.html';
  res.sendFile(path.join(__dirname, 'public', file));
});

app.listen(PORT, '0.0.0.0', () => {
  console.log(`Exercice SEM app running on port ${PORT}`);
  console.log(`Supabase URL: ${process.env.SUPABASE_URL ? 'configured' : 'NOT SET'}`);
});
