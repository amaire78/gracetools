-- GraceTools Database Schema & RPC Functions
-- From GRACETOOLS_DEPLOYMENT_MANUAL.md (Phase 3)

-- 1. Create users table
CREATE TABLE IF NOT EXISTS users (
  id UUID DEFAULT gen_random_uuid() PRIMARY KEY,
  email TEXT UNIQUE NOT NULL,
  password_hash TEXT,
  display_name TEXT,
  church_name TEXT,
  denomination TEXT,
  credits_balance INT DEFAULT 0,
  created_at TIMESTAMP DEFAULT NOW(),
  updated_at TIMESTAMP DEFAULT NOW(),
  deleted_at TIMESTAMP
);

-- 2. Create projects table
CREATE TABLE IF NOT EXISTS projects (
  id UUID DEFAULT gen_random_uuid() PRIMARY KEY,
  user_id UUID REFERENCES users(id) ON DELETE CASCADE,
  title TEXT,
  status TEXT DEFAULT 'pending', -- pending, generating, ready, failed, archived
  input_type TEXT, -- passage, topic, youtube, audio, pdf, notes
  input_content TEXT,
  base_package TEXT, -- essentials, preacher, master
  sermon_settings JSONB,
  selected_addons TEXT[],
  credits_used INT,
  error_message TEXT,
  sermon_json JSONB,
  file_paths JSONB,
  created_at TIMESTAMP DEFAULT NOW(),
  completed_at TIMESTAMP,
  deleted_at TIMESTAMP
);

-- 3. Create credit_transactions table
CREATE TABLE IF NOT EXISTS credit_transactions (
  id UUID DEFAULT gen_random_uuid() PRIMARY KEY,
  user_id UUID REFERENCES users(id) ON DELETE CASCADE,
  amount INT NOT NULL,
  type TEXT NOT NULL, -- purchase, used, refund, bonus
  project_id UUID REFERENCES projects(id) ON DELETE SET NULL,
  stripe_charge_id TEXT,
  stripe_event_id TEXT,
  amount_paid_cents INT,
  notes TEXT,
  created_at TIMESTAMP DEFAULT NOW()
);

-- 4. Create audit_log table
CREATE TABLE IF NOT EXISTS audit_log (
  id UUID DEFAULT gen_random_uuid() PRIMARY KEY,
  user_id UUID REFERENCES users(id) ON DELETE CASCADE,
  action TEXT NOT NULL,
  details JSONB,
  ip_address TEXT,
  created_at TIMESTAMP DEFAULT NOW()
);

-- Create indexes for performance
CREATE INDEX IF NOT EXISTS idx_projects_user_id ON projects(user_id);
CREATE INDEX IF NOT EXISTS idx_projects_status ON projects(status);
CREATE INDEX IF NOT EXISTS idx_credit_transactions_user_id ON credit_transactions(user_id);
CREATE INDEX IF NOT EXISTS idx_users_email ON users(email);

-- Enable Row Level Security (RLS) for security
ALTER TABLE users ENABLE ROW LEVEL SECURITY;
ALTER TABLE projects ENABLE ROW LEVEL SECURITY;
ALTER TABLE credit_transactions ENABLE ROW LEVEL SECURITY;

-- Create RLS policy: Users can only see their own data
DROP POLICY IF EXISTS "Users can view own data" ON users;
CREATE POLICY "Users can view own data" ON users
  FOR SELECT USING (auth.uid() = id);

DROP POLICY IF EXISTS "Users can view own projects" ON projects;
CREATE POLICY "Users can view own projects" ON projects
  FOR SELECT USING (auth.uid() = user_id);

DROP POLICY IF EXISTS "Users can view own transactions" ON credit_transactions;
CREATE POLICY "Users can view own transactions" ON credit_transactions
  FOR SELECT USING (auth.uid() = user_id);


-- 5. RPC Functions

-- Function to add credits (called by Stripe payment workflow)
CREATE OR REPLACE FUNCTION add_credits(
  p_user_email TEXT,
  p_amount INT,
  p_type TEXT DEFAULT 'purchase',
  p_stripe_charge_id TEXT DEFAULT NULL
) RETURNS void AS $$
BEGIN
  UPDATE users 
  SET credits_balance = credits_balance + p_amount,
      updated_at = NOW()
  WHERE email = p_user_email;
  
  INSERT INTO credit_transactions (user_id, amount, type, stripe_charge_id)
  SELECT id, p_amount, p_type, p_stripe_charge_id
  FROM users WHERE email = p_user_email;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

-- Function to deduct credits (called before sermon generation)
CREATE OR REPLACE FUNCTION deduct_credits(
  p_user_id UUID,
  p_amount INT,
  p_project_id UUID DEFAULT NULL
) RETURNS void AS $$
DECLARE
  current_balance INT;
BEGIN
  SELECT credits_balance INTO current_balance FROM users WHERE id = p_user_id;
  
  IF current_balance < p_amount THEN
    RAISE EXCEPTION 'Insufficient credits';
  END IF;
  
  UPDATE users 
  SET credits_balance = credits_balance - p_amount,
      updated_at = NOW()
  WHERE id = p_user_id;
  
  INSERT INTO credit_transactions (user_id, amount, type, project_id)
  VALUES (p_user_id, -p_amount, 'used', p_project_id);
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

-- Function to refund credits (called if generation fails)
CREATE OR REPLACE FUNCTION refund_credits(
  p_user_id UUID,
  p_amount INT,
  p_project_id UUID DEFAULT NULL,
  p_reason TEXT DEFAULT 'Generation failed'
) RETURNS void AS $$
BEGIN
  UPDATE users 
  SET credits_balance = credits_balance + p_amount,
      updated_at = NOW()
  WHERE id = p_user_id;
  
  INSERT INTO credit_transactions (user_id, amount, type, project_id, notes)
  VALUES (p_user_id, p_amount, 'refund', p_project_id, p_reason);
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

-- Function to get daily statistics (called by admin summary workflow)
CREATE OR REPLACE FUNCTION get_daily_stats()
RETURNS JSON AS $$
DECLARE
  result JSON;
  yesterday_start TIMESTAMPTZ := DATE_TRUNC('day', NOW() - INTERVAL '1 day');
  yesterday_end   TIMESTAMPTZ := DATE_TRUNC('day', NOW());
BEGIN
  SELECT json_build_object(
    'new_users_yesterday',    (SELECT COUNT(*) FROM users WHERE created_at BETWEEN yesterday_start AND yesterday_end),
    'revenue_yesterday',      (SELECT COALESCE(SUM(amount_paid_cents)/100.0, 0)::NUMERIC(10,2) FROM credit_transactions WHERE type='purchase' AND created_at BETWEEN yesterday_start AND yesterday_end),
    'projects_yesterday',     (SELECT COUNT(*) FROM projects WHERE created_at BETWEEN yesterday_start AND yesterday_end),
    'failed_yesterday',       (SELECT COUNT(*) FROM projects WHERE status='failed' AND created_at BETWEEN yesterday_start AND yesterday_end),
    'credits_sold_yesterday', (SELECT COALESCE(SUM(amount),0) FROM credit_transactions WHERE type='purchase' AND created_at BETWEEN yesterday_start AND yesterday_end),
    'total_users',            (SELECT COUNT(*) FROM users WHERE deleted_at IS NULL),
    'total_revenue',          (SELECT COALESCE(SUM(amount_paid_cents)/100.0,0)::NUMERIC(10,2) FROM credit_transactions WHERE type='purchase'),
    'total_projects',         (SELECT COUNT(*) FROM projects),
    'top_package',            (SELECT base_package FROM projects WHERE created_at BETWEEN yesterday_start AND yesterday_end GROUP BY base_package ORDER BY COUNT(*) DESC LIMIT 1)
  ) INTO result;
  RETURN result;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

-- Function to clean up expired sessions
CREATE OR REPLACE FUNCTION cleanup_expired_sessions()
RETURNS void AS $$
BEGIN
  DELETE FROM projects WHERE status='generating' AND created_at < NOW() - INTERVAL '24 hours';
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;
