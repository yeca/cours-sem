require('dotenv').config();
const express = require('express');
const path = require('path');

const app = express();
const PORT = process.env.PORT || 3000;

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

// Serve static files
app.use(express.static(path.join(__dirname, 'public')));

// SPA fallback — all routes serve index.html
app.get('*', (req, res) => {
  // Known routes
  const routes = ['/', '/app', '/prof', '/login', '/register'];
  const file = req.path === '/prof' ? 'prof.html'
    : req.path === '/app' ? 'app.html'
    : 'index.html';
  res.sendFile(path.join(__dirname, 'public', file));
});

app.listen(PORT, '0.0.0.0', () => {
  console.log(`Exercice SEM app running on port ${PORT}`);
  console.log(`Supabase URL: ${process.env.SUPABASE_URL ? 'configured' : 'NOT SET'}`);
});
