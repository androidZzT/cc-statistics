/**
 * 主逻辑：数据获取、UI 更新
 */

let currentProject = '';
let currentDays = 1;

// ── CountUp 动画 ──
function countUp(el, target, duration) {
    duration = duration || 600;
    const start = parseInt(el.textContent) || 0;
    if (start === target) return;

    const startTime = performance.now();
    const diff = target - start;

    function tick(now) {
        const elapsed = now - startTime;
        const progress = Math.min(elapsed / duration, 1);
        const ease = 1 - Math.pow(1 - progress, 3);
        const current = Math.round(start + diff * ease);
        el.textContent = formatNumber(current);
        if (progress < 1) requestAnimationFrame(tick);
    }

    requestAnimationFrame(tick);
}

function formatNumber(n) {
    if (n >= 1e6) return (n / 1e6).toFixed(1) + 'M';
    if (n >= 1e3) return (n / 1e3).toFixed(1) + 'K';
    return n.toLocaleString();
}

// ── API 调用 ──
async function apiGet(path, params) {
    const url = new URL(path, window.location.origin);
    if (params) {
        Object.entries(params).forEach(function(entry) {
            if (entry[1] != null && entry[1] !== '') {
                url.searchParams.set(entry[0], entry[1]);
            }
        });
    }
    const resp = await fetch(url);
    return resp.json();
}

// ── 加载项目列表 ──
async function loadProjects() {
    const select = document.getElementById('project-select');
    try {
        const projects = await apiGet('/api/projects');
        select.innerHTML = '<option value="">All Projects</option>';
        projects.forEach(function(p) {
            const opt = document.createElement('option');
            opt.value = p.dir_name;
            const parts = p.display_name.split('/');
            const shortName = parts.slice(-2).join('/');
            opt.textContent = shortName + ' (' + p.session_count + ')';
            select.appendChild(opt);
        });
    } catch (e) {
        console.error('Failed to load projects:', e);
    }
}

// ── 加载统计数据 ──
async function loadStats() {
    var sinceDays = currentDays > 0 ? currentDays : 0;

    try {
        var statsParams = { days: sinceDays };
        var dailyParams = { days: currentDays > 0 ? currentDays : 365 };

        if (currentProject) {
            statsParams.project = currentProject;
            dailyParams.project = currentProject;
        }

        const [stats, daily] = await Promise.all([
            apiGet('/api/stats', statsParams),
            apiGet('/api/daily_stats', dailyParams),
        ]);

        if (stats.error) {
            showEmpty(stats.error);
            return;
        }

        updateMetrics(stats);
        renderToolChart(stats);
        renderTimeChart(stats);
        renderLangChart(stats);
        renderTokenChart(stats);
        renderTrendChart(daily);

        // Session info
        const info = document.getElementById('session-info');
        info.textContent = stats.session_count + ' sessions analyzed';
        if (stats.start_time && stats.end_time) {
            const start = new Date(stats.start_time).toLocaleDateString();
            const end = new Date(stats.end_time).toLocaleDateString();
            info.textContent += ' | ' + start + ' — ' + end;
        }
    } catch (e) {
        console.error('Failed to load stats:', e);
        showEmpty('Failed to load data');
    }
}

function updateMetrics(data) {
    // Messages
    countUp(document.getElementById('val-messages'), data.user_message_count);
    document.getElementById('sub-messages').textContent =
        data.turn_count + ' turns';

    // Tools
    countUp(document.getElementById('val-tools'), data.tool_call_total);
    var topTool = data.tool_calls.length > 0 ? data.tool_calls[0].name : '';
    document.getElementById('sub-tools').textContent =
        topTool ? 'Top: ' + topTool : '';

    // Duration
    document.getElementById('val-duration').textContent = data.active_duration_fmt;
    var aiPct = data.active_duration > 0
        ? Math.round(data.ai_duration / data.active_duration * 100) : 0;
    document.getElementById('sub-duration').textContent =
        'AI ' + aiPct + '% | Total ' + data.total_duration_fmt;

    // Code changes
    var netLines = data.total_added - data.total_removed;
    var sign = netLines >= 0 ? '+' : '';
    document.getElementById('val-code').textContent =
        sign + formatNumber(netLines);
    document.getElementById('sub-code').textContent =
        '+' + formatNumber(data.total_added) + ' / -' + formatNumber(data.total_removed);

    // Tokens
    document.getElementById('val-tokens').textContent =
        formatTokenCount(data.token_usage.total);
    document.getElementById('sub-tokens').textContent =
        'In: ' + formatTokenCount(data.token_usage.input_tokens) +
        ' Out: ' + formatTokenCount(data.token_usage.output_tokens);
}

function showEmpty(msg) {
    document.getElementById('val-messages').textContent = '—';
    document.getElementById('val-tools').textContent = '—';
    document.getElementById('val-duration').textContent = '—';
    document.getElementById('val-code').textContent = '—';
    document.getElementById('val-tokens').textContent = '—';
    document.getElementById('session-info').textContent = msg || 'No data';
}

// ── 事件绑定 ──
function bindEvents() {
    document.getElementById('project-select').addEventListener('change', function(e) {
        currentProject = e.target.value;
        loadStats();
    });

    document.querySelectorAll('.time-btn').forEach(function(btn) {
        btn.addEventListener('click', function() {
            document.querySelectorAll('.time-btn').forEach(function(b) {
                b.classList.remove('active');
            });
            btn.classList.add('active');
            currentDays = parseInt(btn.dataset.days);
            loadStats();
        });
    });
}

// ── 启动 ──
function init() {
    bindEvents();
    loadProjects();
    loadStats();
}

init();
