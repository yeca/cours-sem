/**
 * Script one-shot: génère un PDF pour chaque groupe existant.
 * Utilise Puppeteer avec un contexte isolé par groupe.
 */
require('dotenv').config();
const puppeteer = require('puppeteer');
const { createClient } = require('@supabase/supabase-js');
const crypto = require('crypto');

const SUPABASE_URL = process.env.SUPABASE_URL;
const SERVICE_KEY = process.env.SUPABASE_SERVICE_ROLE_KEY;
const APP_URL = `http://localhost:${process.env.PORT || 3000}`;
const PROF_EMAILS = (process.env.PROF_EMAILS || '').split(',').map(e => e.trim().toLowerCase());

const supabaseAdmin = createClient(SUPABASE_URL, SERVICE_KEY, { db: { schema: 'courssem' } });
const TEMP_PASS = 'TempPdfGen_' + crypto.randomBytes(8).toString('hex');

async function main() {
  const { data: groups } = await supabaseAdmin.from('sem_groups').select('id, group_name');
  console.log(`Found ${groups.length} groups`);

  const targets = [];
  for (const g of groups) {
    const { data: members } = await supabaseAdmin.from('sem_profiles').select('id, email').eq('group_id', g.id);
    if (!members || members.length === 0) { console.log(`  Skip "${g.group_name}" — no members`); continue; }
    // Pick a non-prof member
    const member = members.find(m => !PROF_EMAILS.includes(m.email.toLowerCase())) || members[0];
    targets.push({ ...g, userId: member.id, email: member.email });
  }

  const browser = await puppeteer.launch({ headless: 'new', args: ['--no-sandbox', '--disable-setuid-sandbox'] });

  for (const g of targets) {
    console.log(`\n--- Group "${g.group_name}" (${g.email}) ---`);
    let context, page;
    try {
      // Set temp password
      const { error: pwErr } = await supabaseAdmin.auth.admin.updateUserById(g.userId, { password: TEMP_PASS });
      if (pwErr) { console.error(`  Password update failed: ${pwErr.message}`); continue; }

      // Isolated browser context (clean cookies/storage)
      context = await browser.createBrowserContext();
      page = await context.newPage();
      page.setDefaultTimeout(30000);

      // Go to login page
      await page.goto(APP_URL, { waitUntil: 'networkidle2' });

      // Login
      await page.waitForSelector('#login-email');
      await page.type('#login-email', g.email);
      await page.type('#login-password', TEMP_PASS);
      await page.click('#btn-login');

      // Wait for redirect to /app
      await page.waitForFunction(() => window.location.pathname === '/app', { timeout: 15000 });
      await page.waitForSelector('#btn-present', { timeout: 15000 });

      // Wait for data to load
      await new Promise(r => setTimeout(r, 3000));
      console.log(`  Logged in, generating presentation...`);

      // Click "Generate presentation"
      await page.click('#btn-present');
      await page.waitForSelector('.pres-overlay.show', { timeout: 10000 });
      console.log(`  Presentation open, waiting for PDF auto-save...`);

      // Wait for PDF save (max 3 min)
      await page.waitForFunction(() => {
        const s = document.getElementById('autosave-status');
        if (!s) return false;
        const t = s.textContent;
        return t.includes('PDF sauvegarde') || t.includes('Erreur sauvegarde') || t.includes('Sauvegarde a');
      }, { timeout: 180000 });

      const status = await page.$eval('#autosave-status', el => el.textContent);
      console.log(`  Result: ${status}`);

    } catch (err) {
      console.error(`  Error: ${err.message}`);
    } finally {
      if (context) await context.close().catch(() => {});
    }
  }

  await browser.close();
  console.log('\nDone!');
}

main().catch(err => { console.error('Fatal:', err); process.exit(1); });
