-- ============================================================
-- Migration: Exercice SEM — schema courssem
-- A executer dans le SQL Editor de Supabase Studio
-- ============================================================

-- 1. Creer le schema
CREATE SCHEMA IF NOT EXISTS courssem;

-- 2. Autoriser PostgREST a utiliser ce schema
GRANT USAGE ON SCHEMA courssem TO anon, authenticated, service_role;

-- 3. Table des profils etudiants
CREATE TABLE courssem.sem_profiles (
  id UUID PRIMARY KEY REFERENCES auth.users(id) ON DELETE CASCADE,
  full_name TEXT,
  email TEXT,
  created_at TIMESTAMPTZ DEFAULT now()
);

-- 4. Table des exercices
CREATE TABLE courssem.sem_exercises (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id UUID NOT NULL REFERENCES auth.users(id) ON DELETE CASCADE,
  title TEXT DEFAULT 'Mon exercice SEM',
  data JSONB DEFAULT '{}'::jsonb,
  progress INTEGER DEFAULT 0,
  submitted BOOLEAN DEFAULT false,
  submitted_at TIMESTAMPTZ,
  created_at TIMESTAMPTZ DEFAULT now(),
  updated_at TIMESTAMPTZ DEFAULT now()
);

-- 5. Index
CREATE INDEX idx_sem_exercises_user_id ON courssem.sem_exercises(user_id);

-- 6. Trigger pour updated_at
CREATE OR REPLACE FUNCTION courssem.update_updated_at()
RETURNS TRIGGER AS $$
BEGIN
  NEW.updated_at = now();
  RETURN NEW;
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER trg_updated_at
  BEFORE UPDATE ON courssem.sem_exercises
  FOR EACH ROW EXECUTE FUNCTION courssem.update_updated_at();

-- 7. Trigger pour creer le profil automatiquement a l'inscription
CREATE OR REPLACE FUNCTION courssem.handle_new_user()
RETURNS TRIGGER AS $$
BEGIN
  INSERT INTO courssem.sem_profiles (id, full_name, email)
  VALUES (
    NEW.id,
    COALESCE(NEW.raw_user_meta_data->>'full_name', ''),
    NEW.email
  );
  RETURN NEW;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

-- Supprimer le trigger s'il existe deja
DROP TRIGGER IF EXISTS on_auth_user_created_courssem ON auth.users;
CREATE TRIGGER on_auth_user_created_courssem
  AFTER INSERT ON auth.users
  FOR EACH ROW EXECUTE FUNCTION courssem.handle_new_user();

-- 8. RLS (Row Level Security)
ALTER TABLE courssem.sem_profiles ENABLE ROW LEVEL SECURITY;
ALTER TABLE courssem.sem_exercises ENABLE ROW LEVEL SECURITY;

-- Profils : chacun voit le sien, les profs voient tout
CREATE POLICY "Users can view own profile"
  ON courssem.sem_profiles FOR SELECT
  USING (auth.uid() = id);

CREATE POLICY "Users can update own profile"
  ON courssem.sem_profiles FOR UPDATE
  USING (auth.uid() = id);

-- Exercices : chacun gere les siens
CREATE POLICY "Users can view own exercises"
  ON courssem.sem_exercises FOR SELECT
  USING (auth.uid() = user_id);

CREATE POLICY "Users can insert own exercises"
  ON courssem.sem_exercises FOR INSERT
  WITH CHECK (auth.uid() = user_id);

CREATE POLICY "Users can update own exercises"
  ON courssem.sem_exercises FOR UPDATE
  USING (auth.uid() = user_id);

-- Service role (prof dashboard) peut tout lire
CREATE POLICY "Service role can read all profiles"
  ON courssem.sem_profiles FOR SELECT
  USING (auth.role() = 'service_role');

CREATE POLICY "Service role can read all exercises"
  ON courssem.sem_exercises FOR SELECT
  USING (auth.role() = 'service_role');

-- 9. Permissions par defaut pour les futures tables
ALTER DEFAULT PRIVILEGES IN SCHEMA courssem
  GRANT SELECT, INSERT, UPDATE, DELETE ON TABLES TO anon, authenticated, service_role;

-- Permissions sur les tables existantes
GRANT SELECT, INSERT, UPDATE, DELETE ON ALL TABLES IN SCHEMA courssem TO anon, authenticated, service_role;
