# GraceTools Deployment Brief

## Phase 1: Local Preparation
- Initialize git repository in `C:\Users\andre\hermes-gracetools`
- Verify project files (including `gracetools-standalone.html` and workspace structure)
- Set up local environment variables (`.env.example`)
- Gather required credentials and configuration parameters from the user (GitHub username/token, Supabase URL/keys, Vercel token, etc.)

## Phase 2: GitHub Repository Setup & Code Push
- Create or link the GitHub repository for GraceTools
- Commit and push project files to GitHub

## Phase 3: Supabase Database Setup
- Create and configure Supabase project
- Apply database schema and migrations

## Phase 4: n8n Workflows Import
- Import required n8n automation workflows

## Phase 5: Vercel Deployment
- Connect repository to Vercel
- Configure environment variables and deploy production build
