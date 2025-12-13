# N2X - 自用备份

# 一键安装

```
wget -N https://raw.githubusercontent.com/Designdocs/N2X-script/main/install.sh && bash install.sh
```

## .env（敏感信息分离）

- 生成的 `/etc/N2X/config.json` 会引用环境变量（例如 `${N2X_API_KEY}`），真实值放在 `/etc/N2X/.env`
- 模板：`N2X-script/.env.example`（也会在 generate 时输出到 `/etc/N2X/.env.example`）
