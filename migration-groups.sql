-- ============================================================
-- Migration: Exercice SEM — Passage au mode groupe
-- A executer dans le SQL Editor de Supabase Studio
-- APRES migration.sql
-- ============================================================

-- 1. Table des groupes
CREATE TABLE courssem.sem_groups (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  group_name TEXT UNIQUE NOT NULL,
  created_by UUID REFERENCES auth.users(id) ON DELETE SET NULL,
  created_at TIMESTAMPTZ DEFAULT now()
);

-- 2. Modifier sem_profiles : ajouter group_id, first_name, last_name
ALTER TABLE courssem.sem_profiles
  ADD COLUMN group_id UUID REFERENCES courssem.sem_groups(id) ON DELETE SET NULL,
  ADD COLUMN first_name TEXT DEFAULT '',
  ADD COLUMN last_name TEXT DEFAULT '';

CREATE INDEX idx_sem_profiles_group_id ON courssem.sem_profiles(group_id);

-- 3. Modifier sem_exercises : ajouter group_id, rendre user_id nullable
ALTER TABLE courssem.sem_exercises
  ADD COLUMN group_id UUID REFERENCES courssem.sem_groups(id) ON DELETE CASCADE;

ALTER TABLE courssem.sem_exercises ALTER COLUMN user_id DROP NOT NULL;

CREATE INDEX idx_sem_exercises_group_id ON courssem.sem_exercises(group_id);
ALTER TABLE courssem.sem_exercises ADD CONSTRAINT uq_sem_exercises_group UNIQUE (group_id);

-- 4. Mettre a jour le trigger handle_new_user pour supporter les groupes
CREATE OR REPLACE FUNCTION courssem.handle_new_user()
RETURNS TRIGGER AS $$
BEGIN
  INSERT INTO courssem.sem_profiles (id, full_name, first_name, last_name, email, group_id)
  VALUES (
    NEW.id,
    COALESCE(NEW.raw_user_meta_data->>'full_name', ''),
    COALESCE(NEW.raw_user_meta_data->>'first_name', ''),
    COALESCE(NEW.raw_user_meta_data->>'last_name', ''),
    NEW.email,
    (NEW.raw_user_meta_data->>'group_id')::uuid
  );
  RETURN NEW;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

-- 5. Recréer les policies RLS pour le mode groupe

-- Supprimer les anciennes policies
DROP POLICY IF EXISTS "Users can view own profile" ON courssem.sem_profiles;
DROP POLICY IF EXISTS "Users can update own profile" ON courssem.sem_profiles;
DROP POLICY IF EXISTS "Users can view own exercises" ON courssem.sem_exercises;
DROP POLICY IF EXISTS "Users can insert own exercises" ON courssem.sem_exercises;
DROP POLICY IF EXISTS "Users can update own exercises" ON courssem.sem_exercises;

-- Profiles : voir les membres du meme groupe
CREATE POLICY "Users can view group profiles"
  ON courssem.sem_profiles FOR SELECT
  USING (
    group_id IN (SELECT p.group_id FROM courssem.sem_profiles p WHERE p.id = auth.uid())
    OR id = auth.uid()
  );

CREATE POLICY "Users can update own profile"
  ON courssem.sem_profiles FOR UPDATE
  USING (auth.uid() = id);

-- Exercices : les membres du groupe peuvent voir, creer, modifier
CREATE POLICY "Group members can view exercises"
  ON courssem.sem_exercises FOR SELECT
  USING (
    group_id IN (SELECT p.group_id FROM courssem.sem_profiles p WHERE p.id = auth.uid())
  );

CREATE POLICY "Group members can insert exercises"
  ON courssem.sem_exercises FOR INSERT
  WITH CHECK (
    group_id IN (SELECT p.group_id FROM courssem.sem_profiles p WHERE p.id = auth.uid())
  );

CREATE POLICY "Group members can update exercises"
  ON courssem.sem_exercises FOR UPDATE
  USING (
    group_id IN (SELECT p.group_id FROM courssem.sem_profiles p WHERE p.id = auth.uid())
  );

-- Groupes : RLS
ALTER TABLE courssem.sem_groups ENABLE ROW LEVEL SECURITY;

CREATE POLICY "Users can view own group"
  ON courssem.sem_groups FOR SELECT
  USING (
    id IN (SELECT p.group_id FROM courssem.sem_profiles p WHERE p.id = auth.uid())
  );

CREATE POLICY "Service role can read all groups"
  ON courssem.sem_groups FOR SELECT
  USING (auth.role() = 'service_role');

CREATE POLICY "Service role can insert groups"
  ON courssem.sem_groups FOR INSERT
  WITH CHECK (auth.role() = 'service_role');

-- Permissions sur la nouvelle table
GRANT SELECT, INSERT, UPDATE, DELETE ON courssem.sem_groups TO anon, authenticated, service_role;
