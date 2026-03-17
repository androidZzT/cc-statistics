/**
 * Chart.js 图表封装
 */

// Chart.js 全局配置
Chart.defaults.color = '#8b949e';
Chart.defaults.borderColor = 'rgba(48, 54, 61, 0.4)';
Chart.defaults.font.family = "-apple-system, BlinkMacSystemFont, 'SF Pro Display', sans-serif";
Chart.defaults.font.size = 11;
Chart.defaults.plugins.legend.labels.boxWidth = 10;
Chart.defaults.plugins.legend.labels.padding = 12;
Chart.defaults.animation.duration = 800;
Chart.defaults.animation.easing = 'easeOutQuart';

const COLORS = {
    blue: '#58a6ff',
    green: '#3fb950',
    purple: '#bc8cff',
    orange: '#f0883e',
    red: '#f85149',
    cyan: '#39d2c0',
    pink: '#f778ba',
    yellow: '#d29922',
};

const PALETTE = [
    COLORS.blue, COLORS.green, COLORS.purple, COLORS.orange,
    COLORS.cyan, COLORS.pink, COLORS.red, COLORS.yellow,
];

// 存储 chart 实例以便销毁重建
const charts = {};

function destroyChart(id) {
    if (charts[id]) {
        charts[id].destroy();
        delete charts[id];
    }
}

/**
 * 工具调用柱状图
 */
function renderToolChart(data) {
    destroyChart('tools');
    const ctx = document.getElementById('chart-tools');
    if (!data || !data.tool_calls || data.tool_calls.length === 0) return;

    const items = data.tool_calls.slice(0, 8);
    charts['tools'] = new Chart(ctx, {
        type: 'bar',
        data: {
            labels: items.map(t => t.name),
            datasets: [{
                data: items.map(t => t.count),
                backgroundColor: items.map((_, i) => PALETTE[i % PALETTE.length] + '80'),
                borderColor: items.map((_, i) => PALETTE[i % PALETTE.length]),
                borderWidth: 1,
                borderRadius: 4,
            }],
        },
        options: {
            indexAxis: 'y',
            responsive: true,
            maintainAspectRatio: false,
            plugins: {
                legend: { display: false },
                tooltip: {
                    backgroundColor: 'rgba(22, 27, 34, 0.95)',
                    borderColor: 'rgba(48, 54, 61, 0.6)',
                    borderWidth: 1,
                    titleColor: '#e6edf3',
                    bodyColor: '#8b949e',
                    padding: 10,
                    cornerRadius: 8,
                },
            },
            scales: {
                x: {
                    grid: { display: false },
                    ticks: { display: false },
                },
                y: {
                    grid: { display: false },
                    ticks: { font: { size: 11 } },
                },
            },
        },
    });
}

/**
 * 时长分布饼图
 */
function renderTimeChart(data) {
    destroyChart('time');
    const ctx = document.getElementById('chart-time');
    if (!data) return;

    const aiMin = Math.round(data.ai_duration / 60);
    const userMin = Math.round(data.user_duration / 60);
    const idleMin = Math.max(0, Math.round((data.total_duration - data.active_duration) / 60));

    if (aiMin + userMin + idleMin === 0) return;

    charts['time'] = new Chart(ctx, {
        type: 'doughnut',
        data: {
            labels: ['AI Processing', 'User Active', 'Idle'],
            datasets: [{
                data: [aiMin, userMin, idleMin],
                backgroundColor: [COLORS.blue + 'cc', COLORS.green + 'cc', 'rgba(48, 54, 61, 0.6)'],
                borderColor: [COLORS.blue, COLORS.green, 'rgba(48, 54, 61, 0.8)'],
                borderWidth: 1,
            }],
        },
        options: {
            responsive: true,
            maintainAspectRatio: false,
            cutout: '60%',
            plugins: {
                legend: {
                    position: 'right',
                    labels: { padding: 16, font: { size: 11 } },
                },
                tooltip: {
                    backgroundColor: 'rgba(22, 27, 34, 0.95)',
                    borderColor: 'rgba(48, 54, 61, 0.6)',
                    borderWidth: 1,
                    padding: 10,
                    cornerRadius: 8,
                    callbacks: {
                        label: function(ctx) {
                            return ctx.label + ': ' + ctx.parsed + ' min';
                        },
                    },
                },
            },
        },
    });
}

/**
 * 代码变更按语言堆叠柱状图
 */
function renderLangChart(data) {
    destroyChart('langs');
    const ctx = document.getElementById('chart-langs');
    if (!data || !data.lines_by_lang || data.lines_by_lang.length === 0) return;

    const items = data.lines_by_lang.slice(0, 8);

    charts['langs'] = new Chart(ctx, {
        type: 'bar',
        data: {
            labels: items.map(l => l.lang),
            datasets: [
                {
                    label: 'Added',
                    data: items.map(l => l.added),
                    backgroundColor: COLORS.green + '80',
                    borderColor: COLORS.green,
                    borderWidth: 1,
                    borderRadius: 4,
                },
                {
                    label: 'Removed',
                    data: items.map(l => -l.removed),
                    backgroundColor: COLORS.red + '80',
                    borderColor: COLORS.red,
                    borderWidth: 1,
                    borderRadius: 4,
                },
            ],
        },
        options: {
            responsive: true,
            maintainAspectRatio: false,
            plugins: {
                legend: {
                    position: 'top',
                    labels: { font: { size: 10 } },
                },
                tooltip: {
                    backgroundColor: 'rgba(22, 27, 34, 0.95)',
                    borderColor: 'rgba(48, 54, 61, 0.6)',
                    borderWidth: 1,
                    padding: 10,
                    cornerRadius: 8,
                    callbacks: {
                        label: function(ctx) {
                            const val = Math.abs(ctx.parsed.y);
                            return ctx.dataset.label + ': ' + val + ' lines';
                        },
                    },
                },
            },
            scales: {
                x: { grid: { display: false }, stacked: true },
                y: { grid: { color: 'rgba(48, 54, 61, 0.3)' }, stacked: true },
            },
        },
    });
}

/**
 * Token 分布图
 */
function renderTokenChart(data) {
    destroyChart('tokens');
    const ctx = document.getElementById('chart-tokens');
    if (!data || !data.token_usage) return;

    const tu = data.token_usage;
    const values = [tu.input_tokens, tu.output_tokens, tu.cache_read, tu.cache_creation];
    if (values.every(v => v === 0)) return;

    charts['tokens'] = new Chart(ctx, {
        type: 'doughnut',
        data: {
            labels: ['Input', 'Output', 'Cache Read', 'Cache Create'],
            datasets: [{
                data: values,
                backgroundColor: [
                    COLORS.blue + 'cc',
                    COLORS.purple + 'cc',
                    COLORS.cyan + 'cc',
                    COLORS.orange + 'cc',
                ],
                borderColor: [COLORS.blue, COLORS.purple, COLORS.cyan, COLORS.orange],
                borderWidth: 1,
            }],
        },
        options: {
            responsive: true,
            maintainAspectRatio: false,
            cutout: '60%',
            plugins: {
                legend: {
                    position: 'right',
                    labels: { padding: 16, font: { size: 11 } },
                },
                tooltip: {
                    backgroundColor: 'rgba(22, 27, 34, 0.95)',
                    borderColor: 'rgba(48, 54, 61, 0.6)',
                    borderWidth: 1,
                    padding: 10,
                    cornerRadius: 8,
                    callbacks: {
                        label: function(ctx) {
                            return ctx.label + ': ' + formatTokenCount(ctx.parsed);
                        },
                    },
                },
            },
        },
    });
}

/**
 * 每日活跃趋势折线图
 */
function renderTrendChart(dailyData) {
    destroyChart('trend');
    const ctx = document.getElementById('chart-trend');
    if (!dailyData || dailyData.length === 0) return;

    // 只显示有数据的部分（从第一个有数据的日期开始）
    let startIdx = dailyData.findIndex(d => d.sessions > 0);
    if (startIdx < 0) return;
    const items = dailyData.slice(startIdx);

    charts['trend'] = new Chart(ctx, {
        type: 'line',
        data: {
            labels: items.map(d => {
                const parts = d.date.split('-');
                return parts[1] + '/' + parts[2];
            }),
            datasets: [
                {
                    label: 'Messages',
                    data: items.map(d => d.messages),
                    borderColor: COLORS.blue,
                    backgroundColor: COLORS.blue + '20',
                    fill: true,
                    tension: 0.4,
                    pointRadius: 2,
                    pointHoverRadius: 5,
                    borderWidth: 2,
                },
                {
                    label: 'Tool Calls',
                    data: items.map(d => d.tool_calls),
                    borderColor: COLORS.purple,
                    backgroundColor: 'transparent',
                    tension: 0.4,
                    pointRadius: 2,
                    pointHoverRadius: 5,
                    borderWidth: 2,
                },
                {
                    label: 'Active (min)',
                    data: items.map(d => d.active_minutes),
                    borderColor: COLORS.cyan,
                    backgroundColor: 'transparent',
                    tension: 0.4,
                    pointRadius: 2,
                    pointHoverRadius: 5,
                    borderWidth: 2,
                    hidden: true,
                },
            ],
        },
        options: {
            responsive: true,
            maintainAspectRatio: false,
            interaction: {
                mode: 'index',
                intersect: false,
            },
            plugins: {
                legend: {
                    position: 'top',
                    labels: { font: { size: 11 }, padding: 16 },
                },
                tooltip: {
                    backgroundColor: 'rgba(22, 27, 34, 0.95)',
                    borderColor: 'rgba(48, 54, 61, 0.6)',
                    borderWidth: 1,
                    padding: 10,
                    cornerRadius: 8,
                },
            },
            scales: {
                x: {
                    grid: { display: false },
                    ticks: { maxTicksLimit: 15 },
                },
                y: {
                    grid: { color: 'rgba(48, 54, 61, 0.3)' },
                    beginAtZero: true,
                },
            },
        },
    });
}

/**
 * 格式化 token 数量
 */
function formatTokenCount(n) {
    if (n >= 1e9) return (n / 1e9).toFixed(1) + 'B';
    if (n >= 1e6) return (n / 1e6).toFixed(1) + 'M';
    if (n >= 1e3) return (n / 1e3).toFixed(1) + 'K';
    return n.toString();
}
