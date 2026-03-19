-- ============================================================
-- EXERCICE SEM — Schema Supabase (tables prefixees sem_)
-- Deploye sur MySEO.coach (acpnpowbwvnydrydjiwv)
-- ============================================================

-- 1. Table des profils etudiants (liee a auth.users)
CREATE TABLE IF NOT EXISTS public.sem_profiles (
  id UUID PRIMARY KEY REFERENCES auth.users(id) ON DELETE CASCADE,
  email TEXT NOT NULL,
  full_name TEXT NOT NULL DEFAULT '',
  role TEXT NOT NULL DEFAULT 'student' CHECK (role IN ('student', 'prof')),
  created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

-- 2. Table des exercices
CREATE TABLE IF NOT EXISTS public.sem_exercises (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id UUID NOT NULL REFERENCES auth.users(id) ON DELETE CASCADE,
  title TEXT NOT NULL DEFAULT 'Mon exercice SEM',
  data JSONB NOT NULL DEFAULT '{}'::jsonb,
  progress INTEGER NOT NULL DEFAULT 0 CHECK (progress >= 0 AND progress <= 100),
  submitted BOOLEAN NOT NULL DEFAULT false,
  submitted_at TIMESTAMPTZ,
  created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS idx_sem_exercises_user_id ON public.sem_exercises(user_id);
CREATE INDEX IF NOT EXISTS idx_sem_exercises_submitted ON public.sem_exercises(submitted);

-- 3. Triggers updated_at
CREATE OR REPLACE FUNCTION sem_update_updated_at()
RETURNS TRIGGER AS $$
BEGIN
  NEW.updated_at = now();
  RETURN NEW;
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER trg_sem_profiles_updated_at
  BEFORE UPDATE ON public.sem_profiles
  FOR EACH ROW EXECUTE FUNCTION sem_update_updated_at();

CREATE TRIGGER trg_sem_exercises_updated_at
  BEFORE UPDATE ON public.sem_exercises
  FOR EACH ROW EXECUTE FUNCTION sem_update_updated_at();

-- 4. Trigger auto-creation profil a l'inscription
CREATE OR REPLACE FUNCTION sem_handle_new_user()
RETURNS TRIGGER AS $$
BEGIN
  INSERT INTO public.sem_profiles (id, email, full_name, role)
  VALUES (
    NEW.id,
    NEW.email,
    COALESCE(NEW.raw_user_meta_data->>'full_name', ''),
    COALESCE(NEW.raw_user_meta_data->>'role', 'student')
  )
  ON CONFLICT (id) DO NOTHING;
  RETURN NEW;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

DROP TRIGGER IF EXISTS on_sem_auth_user_created ON auth.users;
CREATE TRIGGER on_sem_auth_user_created
  AFTER INSERT ON auth.users
  FOR EACH ROW EXECUTE FUNCTION sem_handle_new_user();

-- ============================================================
-- ROW LEVEL SECURITY
-- ============================================================

ALTER TABLE public.sem_profiles ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.sem_exercises ENABLE ROW LEVEL SECURITY;

-- Profiles
CREATE POLICY "sem_users_view_own_profile"
  ON public.sem_profiles FOR SELECT
  USING (auth.uid() = id);

CREATE POLICY "sem_users_update_own_profile"
  ON public.sem_profiles FOR UPDATE
  USING (auth.uid() = id);

CREATE POLICY "sem_profs_view_all_profiles"
  ON public.sem_profiles FOR SELECT
  USING (
    EXISTS (
      SELECT 1 FROM public.sem_profiles
      WHERE id = auth.uid() AND role = 'prof'
    )
  );

-- Exercises
CREATE POLICY "sem_users_view_own_exercises"
  ON public.sem_exercises FOR SELECT
  USING (auth.uid() = user_id);

CREATE POLICY "sem_users_insert_own_exercises"
  ON public.sem_exercises FOR INSERT
  WITH CHECK (auth.uid() = user_id);

CREATE POLICY "sem_users_update_own_exercises"
  ON public.sem_exercises FOR UPDATE
  USING (auth.uid() = user_id);

CREATE POLICY "sem_users_delete_own_exercises"
  ON public.sem_exercises FOR DELETE
  USING (auth.uid() = user_id);

CREATE POLICY "sem_profs_view_all_exercises"
  ON public.sem_exercises FOR SELECT
  USING (
    EXISTS (
      SELECT 1 FROM public.sem_profiles
      WHERE id = auth.uid() AND role = 'prof'
    )
  );
