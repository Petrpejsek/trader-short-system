// 🚀 PM2 PRODUCTION KONFIGURACE
// Optimalizováno pro Next.js aplikace s clustering, monitoring a auto-restart
// Umístění: /var/www/trader-app/current/ecosystem.config.js

module.exports = {
  apps: [
    {
      // ===============================
      // MAIN APPLICATION
      // ===============================
      name: 'trader-app',
      script: './server.js', // nebo 'npm' pro Next.js
      args: 'start', // pokud používáte npm script
      cwd: '/var/www/trader-app/current',
      
      // ===============================
      // PROCESS MANAGEMENT
      // ===============================
      instances: 'max', // Využije všechna CPU jádra
      exec_mode: 'cluster', // Cluster mode pro load balancing
      
      // Auto restart konfigurace
      autorestart: true,
      watch: false, // Vypnuto pro production
      max_restarts: 10, // Max restarty za hodinu
      min_uptime: '10s', // Minimální čas před restartem
      
      // Memory management
      max_memory_restart: '1G', // Restart při překročení paměti
      
      // ===============================
      // NETWORKING
      // ===============================
      port: 3000,
      listen_timeout: 10000,
      kill_timeout: 5000,
      wait_ready: true, // Čeká na ready signal
      
      // ===============================
      // ENVIRONMENT
      // ===============================
      env: {
        NODE_ENV: 'production',
        PORT: 3000,
        
        // Database
        DATABASE_URL: 'postgresql://trader_user:password@localhost:5432/trader_production',
        
        // Redis (pokud používáte)
        REDIS_URL: 'redis://localhost:6379',
        
        // Session secret
        SESSION_SECRET: 'your-super-secure-session-secret',
        
        // API Keys (použijte .env soubor)
        NEXTAUTH_SECRET: 'your-nextauth-secret',
        NEXTAUTH_URL: 'https://your-domain.com',
      },
      
      // Development environment (pokud potřeba)
      env_development: {
        NODE_ENV: 'development',
        PORT: 3000,
      },
      
      // Staging environment
      env_staging: {
        NODE_ENV: 'production',
        PORT: 3000,
        DATABASE_URL: 'postgresql://trader_user:password@localhost:5432/trader_staging',
      },
      
      // ===============================
      // LOGGING
      // ===============================
      log_file: '/var/www/trader-app/shared/logs/combined.log',
      out_file: '/var/www/trader-app/shared/logs/out.log',
      error_file: '/var/www/trader-app/shared/logs/error.log',
      
      // Log rotation
      log_date_format: 'YYYY-MM-DD HH:mm:ss Z',
      merge_logs: true,
      
      // ===============================
      // MONITORING & HEALTH CHECKS
      // ===============================
      // Health check konfigurace
      health_check_grace_period: 3000, // Grace period po startu
      health_check_fatal_exceptions: true,
      
      // Advanced monitoring
      pmx: true, // Povolení PMX monitoringu
      
      // ===============================
      // PERFORMANCE TUNING
      // ===============================
      // Node.js optimalizace
      node_args: [
        '--max-old-space-size=2048', // Max heap size
        '--optimize-for-size', // Optimalizace pro velikost
      ],
      
      // Interpreter options
      interpreter_args: '--harmony',
      
      // ===============================
      // DEPLOYMENT HOOKS
      // ===============================
      // Pre-start hook
      pre_start: 'echo "Starting trader-app..."',
      
      // Post-start hook
      post_start: 'echo "trader-app started successfully"',
      
      // Pre-stop hook
      pre_stop: 'echo "Stopping trader-app..."',
      
      // ===============================
      // ADVANCED SETTINGS
      // ===============================
      // Graceful shutdown
      shutdown_with_message: true,
      
      // Process title
      proc_title: 'trader-app-worker',
      
      // Time before force kill
      kill_timeout: 5000,
      
      // Minimum time before restart
      min_uptime: '10s',
      
      // Maximum number of restarts per hour
      max_restarts: 10,
      
      // Exponential backoff restart delay
      restart_delay: 4000,
      
      // ===============================
      // CUSTOM MONITORING
      // ===============================
      // Custom metrics (pokud potřeba)
      monitoring: {
        http: true,
        https: false,
        port: 9615, // PM2 web monitoring port
      },
      
      // Error handling
      catch_exceptions: true,
    },
    
    // ===============================
    // BACKGROUND WORKERS (OPTIONAL)
    // ===============================
    {
      name: 'trader-worker',
      script: './workers/background-worker.js',
      cwd: '/var/www/trader-app/current',
      
      // Single instance pro workers
      instances: 1,
      exec_mode: 'fork',
      
      autorestart: true,
      watch: false,
      max_memory_restart: '512M',
      
      env: {
        NODE_ENV: 'production',
        WORKER_TYPE: 'background',
      },
      
      // Worker-specific logging
      log_file: '/var/www/trader-app/shared/logs/worker.log',
      out_file: '/var/www/trader-app/shared/logs/worker-out.log',
      error_file: '/var/www/trader-app/shared/logs/worker-error.log',
      
      // Cron restart (restart každý den v 3:00)
      cron_restart: '0 3 * * *',
    },
    
    // ===============================
    // SCHEDULED TASKS (OPTIONAL)
    // ===============================
    {
      name: 'trader-scheduler',
      script: './schedulers/daily-tasks.js',
      cwd: '/var/www/trader-app/current',
      
      instances: 1,
      exec_mode: 'fork',
      autorestart: true,
      
      env: {
        NODE_ENV: 'production',
        SCHEDULER_TYPE: 'daily',
      },
      
      // Restart scheduler každých 6 hodin
      cron_restart: '0 */6 * * *',
      
      log_file: '/var/www/trader-app/shared/logs/scheduler.log',
    }
  ],
  
  // ===============================
  // DEPLOYMENT KONFIGURACE
  // ===============================
  deploy: {
    production: {
      user: 'deploy',
      host: ['your-server-ip'], // Můžete mít více serverů
      ref: 'origin/main',
      repo: 'git@github.com:your-username/trader-app.git',
      path: '/var/www/trader-app',
      
      // Pre-deploy hooks
      'pre-deploy-local': 'echo "Pre-deploy validation..."',
      
      // Post-receive hooks
      'post-deploy': [
        'npm install --production',
        'npm run build',
        'pm2 reload ecosystem.config.js --env production',
        'pm2 save'
      ].join(' && '),
      
      // Pre-setup
      'pre-setup': 'apt update && apt install git -y',
      
      // Environment variables
      env: {
        NODE_ENV: 'production'
      }
    },
    
    staging: {
      user: 'deploy',
      host: ['staging-server-ip'],
      ref: 'origin/staging',
      repo: 'git@github.com:your-username/trader-app.git',
      path: '/var/www/trader-app-staging',
      
      'post-deploy': [
        'npm install',
        'npm run build',
        'pm2 reload ecosystem.config.js --env staging'
      ].join(' && '),
      
      env: {
        NODE_ENV: 'staging'
      }
    }
  }
};
