#!/bin/bash

# @sacloud-once
# @sacloud-desc-begin
#   Mastodon on Ubuntu 16.04 LTSのサーバー構築スクリプトです。
#   インスタンス作成時のホスト名には、Mastodonとして利用するFQDNを入力してください。
#   また、そのFQDNが正引きできる必要があります。
#   作成時にいきなりインスタンスを起動せず、割り振られたIPアドレスを確認してDNS登録してから電源を入れましょう。
# @sacloud-desc-end
# @sacloud-require-archive distro-ubuntu distro-ver-16.04.*

FQDN=$(/bin/hostname -f)

# OSアップデート
apt update
apt full-upgrade -y

# メールサーバーインストール
debconf-set-selections <<< "postfix postfix/mailname string $FQDN"
debconf-set-selections <<< "postfix postfix/main_mailer_type string 'Internet Site'"
apt install -y postfix
postconf -e "myorigin = $FQDN"
postconf -e 'smtpd_relay_restrictions = permit_mynetworks defer_unauth_destination'
postconf -e 'mynetworks=127.0.0.0/8'
postconf -e 'inet_protocols = ipv4'
systemctl restart postfix.service

# NGINXインストール
apt install -y nginx

# DNSリバインディング対策
cat >/etc/nginx/sites-available/default <<EOF
server {
    listen 80 default_server;
    listen [::]:80 default_server;

    root /var/www/html;

    server_name _;

    location / {
        return 444;
    }

    location /nginx_status {
        stub_status on;
        access_log off;
        allow 127.0.0.1;
        deny all;
    }

    location ~ /\.ht {
        deny all;
    }
}
EOF

# バーチャルホスト設定
cat >/etc/nginx/sites-available/${FQDN} <<EOF
map \$http_upgrade \$connection_upgrade {
  default upgrade;
  ''      close;
}

server {
  listen 80;
  listen [::]:80;
  server_name ${FQDN};

  location /.well-known {
    root /var/lib/letsencrypt;
  }

  location / {
    return 301 https://\$host\$request_uri;
  }
}
EOF

ln -s /etc/nginx/sites-available/${FQDN} /etc/nginx/sites-enabled/
systemctl restart nginx.service

# Let's Encryptインストール
apt install -y letsencrypt
letsencrypt certonly -n --register-unsafely-without-email --agree-tos --domain=${FQDN} --webroot --webroot-path=/var/lib/letsencrypt
openssl dhparam 2048 -out /etc/nginx/dhparam.pem
cat >>/etc/nginx/sites-available/${FQDN} <<EOF
server {
  listen 443 ssl http2;
  listen [::]:443 ssl http2;
  server_name ${FQDN};

  ssl_protocols TLSv1.2;
  ssl_session_cache shared:SSL:10m;
  ssl_session_timeout 1d;
  ssl_session_tickets off;

  ssl_ciphers 'ECDHE-ECDSA-AES256-GCM-SHA384:ECDHE-RSA-AES256-GCM-SHA384:ECDHE-ECDSA-CHACHA20-POLY1305:ECDHE-RSA-CHACHA20-POLY1305:ECDHE-ECDSA-AES128-GCM-SHA256:ECDHE-RSA-AES128-GCM-SHA256:ECDHE-ECDSA-AES256-SHA384:ECDHE-RSA-AES256-SHA384:ECDHE-ECDSA-AES128-SHA256:ECDHE-RSA-AES128-SHA256';
  ssl_prefer_server_ciphers on;

  ssl_certificate /etc/letsencrypt/live/${FQDN}/fullchain.pem;
  ssl_certificate_key /etc/letsencrypt/live/${FQDN}/privkey.pem;
  ssl_dhparam /etc/nginx/dhparam.pem;

  keepalive_timeout    70;
  sendfile             on;
  client_max_body_size 0;

  root /home/ubuntu/mstdn/public;

  gzip on;
  gzip_disable "msie6";
  gzip_vary on;
  gzip_proxied any;
  gzip_comp_level 6;
  gzip_buffers 16 8k;
  gzip_http_version 1.1;
  gzip_types text/plain text/css application/json application/javascript text/xml application/xml application/xml+rss text/javascript;

  add_header Strict-Transport-Security "max-age=31536000";
  add_header Content-Security-Policy "style-src 'self' 'unsafe-inline'; script-src 'self'; object-src 'self'; img-src data: https:; media-src data: https:; connect-src 'self' wss://${FQDN}; upgrade-insecure-requests";

  location / {
    try_files \$uri @proxy;
  }

  location ~ ^/(assets|system/media_attachments/files|system/accounts/avatars) {
    add_header Cache-Control "public, max-age=31536000, immutable";
    try_files \$uri @proxy;
  }

  location @proxy {
    proxy_set_header Host \$host;
    proxy_set_header X-Real-IP \$remote_addr;
    proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
    proxy_set_header X-Forwarded-Proto https;
    proxy_set_header Proxy "";
    proxy_pass_header Server;

    proxy_pass http://127.0.0.1:3000;
    proxy_buffering off;
    proxy_redirect off;
    proxy_http_version 1.1;
    proxy_set_header Upgrade \$http_upgrade;
    proxy_set_header Connection \$connection_upgrade;

    tcp_nodelay on;
  }

  location /api/v1/streaming {
    proxy_set_header Host \$host;
    proxy_set_header X-Real-IP \$remote_addr;
    proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
    proxy_set_header X-Forwarded-Proto https;
    proxy_set_header Proxy "";

    proxy_pass http://localhost:4000;
    proxy_buffering off;
    proxy_redirect off;
    proxy_http_version 1.1;
    proxy_set_header Upgrade \$http_upgrade;
    proxy_set_header Connection \$connection_upgrade;

    tcp_nodelay on;
  }

  error_page 500 501 502 503 504 /500.html;
}
EOF
systemctl restart nginx.service

cat >/etc/cron.d/renew-ssl <<EOF
0 2 * * 0 root /usr/bin/letsencrypt renew >/dev/null && /usr/sbin/service nginx restart
EOF

# 依存パッケージインストール
apt install -y postgresql redis-server git ruby-dev ruby-build postgresql-server-dev-all npm imagemagick
npm install -g yarn
npm install -g n
n latest

# DBユーザー作成
sed -i -e 's/peer/trust/g' /etc/postgresql/9.5/main/pg_hba.conf
sed -i -e 's/md5/trust/g' /etc/postgresql/9.5/main/pg_hba.conf
systemctl restart postgresql.service
su - postgres -c "createuser --createdb mstdn"

# Rubyインストール
cat >/tmp/setup_ruby.sh <<EOF
git clone https://github.com/sstephenson/rbenv.git ~/.rbenv
echo 'export PATH="~/.rbenv/bin:\$PATH"' >> ~/.profile
source ~/.profile
rbenv init - >> ~/.profile
source ~/.profile
git clone https://github.com/sstephenson/ruby-build.git ~/.rbenv/plugins/ruby-build
rbenv install 2.4.1
rbenv global 2.4.1
rbenv rehash
EOF
chmod +x /tmp/setup_ruby.sh
su - ubuntu -c "/bin/bash /tmp/setup_ruby.sh"

# Mastodonインストール
cat >/tmp/setup_mastodon.sh <<EOF
git clone https://github.com/tootsuite/mastodon.git mstdn
cd mstdn
git checkout v1.3.3
gem install bundler
bundle install --deployment --without development test
yarn install
cp .env.production.sample .env.production
sed -i "s/_HOST=[rd].*/_HOST=localhost/" .env.production
sed -i "s/=postgres\$/=mstdn/" .env.production
sed -i "s/^LOCAL_DOMAIN=.*/LOCAL_DOMAIN=${FQDN}/" .env.production
sed -i "s/^LOCAL_HTTPS.*/LOCAL_HTTPS=true/" .env.production
sed -i "s/^SMTP_SERVER.*/SMTP_SERVER=localhost/" .env.production
sed -i "s/^SMTP_PORT=587/SMTP_PORT=25/" .env.production
sed -i "s/^SMTP_LOGIN/#SMTP_LOGIN/" .env.production
sed -i "s/^SMTP_PASSWORD/#SMTP_PASSWORD/" .env.production
sed -i "s/^#SMTP_AUTH_METHOD.*/SMTP_AUTH_METHOD=none/" .env.production
sed -i "s/^#SMTP_OPENSSL_VERIFY_MODE=.*/SMTP_OPENSSL_VERIFY_MODE=none/" .env.production
sed -i "s/^SMTP_FROM_ADDRESS=.*/SMTP_FROM_ADDRESS=${FQDN}/" .env.production

SECRET_KEY_BASE=\$(bundle exec rake secret)
PAPERCLIP_SECRET=\$(bundle exec rake secret)
OTP_SECRET=\$(bundle exec rake secret)
sed -i "s/^SECRET_KEY_BASE=/SECRET_KEY_BASE=\$(echo -n \${SECRET_KEY_BASE})/" .env.production
sed -i "s/^PAPERCLIP_SECRET=/PAPERCLIP_SECRET=\$(echo -n \${PAPERCLIP_SECRET})/" .env.production
sed -i "s/^OTP_SECRET=/OTP_SECRET=\$(echo -n \${OTP_SECRET})/" .env.production

sed -i "s/:user_name/# :user_name/" config/environments/production.rb
sed -i "s/:password/# :password/" config/environments/production.rb

RAILS_ENV=production bundle exec rails db:setup
RAILS_ENV=production bundle exec rails assets:precompile
EOF
chmod +x /tmp/setup_mastodon.sh
su - ubuntu -c "/bin/bash /tmp/setup_mastodon.sh"

# dailyジョブ登録
echo "5 3 * * * ubuntu cd /home/ubuntu/mstdn && RAILS_ENV=production /home/ubuntu/.rbenv/shims/bundle exec rake mastodon:daily 2>&1 | logger -t mastodon-daily -p local0.info" > /etc/cron.d/mastodon-daily

# systemdユニット作成
cat >/etc/systemd/system/mastodon-web.service <<EOF
[Unit]
Description=mastodon-web
After=network.target

[Service]
Type=simple
User=ubuntu
WorkingDirectory=/home/ubuntu/mstdn
Environment="RAILS_ENV=production"
Environment="PORT=3000"
ExecStart=/home/ubuntu/.rbenv/shims/bundle exec puma -C config/puma.rb
TimeoutSec=15
Restart=always

[Install]
WantedBy=multi-user.target
EOF

cat >/etc/systemd/system/mastodon-sidekiq.service <<EOF
[Unit]
Description=mastodon-sidekiq
After=network.target

[Service]
Type=simple
User=ubuntu
WorkingDirectory=/home/ubuntu/mstdn
Environment="RAILS_ENV=production"
Environment="DB_POOL=5"
ExecStart=/home/ubuntu/.rbenv/shims/bundle exec sidekiq -c 5 -q default -q mailers -q pull -q push
TimeoutSec=15
Restart=always

[Install]
WantedBy=multi-user.target
EOF

cat >/etc/systemd/system/mastodon-streaming.service <<EOF
[Unit]
Description=mastodon-streaming
After=network.target

[Service]
Type=simple
User=ubuntu
WorkingDirectory=/home/ubuntu/mstdn
Environment="NODE_ENV=production"
Environment="PORT=4000"
ExecStart=/usr/bin/npm run start
TimeoutSec=15
Restart=always

[Install]
WantedBy=multi-user.target
EOF

systemctl enable mastodon-{web,sidekiq,streaming}
systemctl start mastodon-{web,sidekiq,streaming}
