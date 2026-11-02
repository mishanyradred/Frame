// Клиентская часть: лента видео по категориям, HLS-плеер и форма загрузки.
const STATUS_LABELS = {
  uploaded: "в очереди",
  processing: "обрабатывается",
  ready: "готово",
  failed: "ошибка",
};

const state = { category: null, categories: [], hls: null, playingId: null, feedTimer: null, feedRequest: 0 };

const $ = (id) => document.getElementById(id);

async function api(path) {
  const response = await fetch(`/api${path}`);
  if (!response.ok) throw new Error(`${response.status} ${response.statusText}`);
  return response.json();
}

function formatDuration(seconds) {
  if (!seconds) return "";
  const s = Math.round(seconds);
  return `${Math.floor(s / 60)}:${String(s % 60).padStart(2, "0")}`;
}

function renderCategories() {
  const nav = $("categories");
  nav.innerHTML = "";
  const items = [{ slug: null, name: "Все" }, ...state.categories];
  for (const cat of items) {
    const button = document.createElement("button");
    button.textContent = cat.name;
    button.className = cat.slug === state.category ? "active" : "";
    button.onclick = () => {
      state.category = cat.slug;
      $("feed-title").textContent = cat.slug ? cat.name : "Все видео";
      renderCategories();
      loadFeed();
    };
    nav.append(button);
  }
  $("upload-category").innerHTML = state.categories
    .map((c) => `<option value="${c.slug}">${c.name}</option>`)
    .join("");
}

function videoCard(video) {
  const card = document.createElement("article");
  card.className = `card status-${video.status}`;
  const thumb = video.thumbnail_url
    ? `<img src="${video.thumbnail_url}" alt="" loading="lazy">`
    : `<div class="placeholder">${STATUS_LABELS[video.status]}</div>`;
  card.innerHTML = `
    <div class="thumb">${thumb}<span class="duration">${formatDuration(video.duration_sec)}</span></div>
    <h3></h3>
    <p class="muted">${video.category_name} · ${new Date(video.created_at).toLocaleString("ru-RU")}</p>
    <span class="badge">${STATUS_LABELS[video.status]}</span>`;
  card.querySelector("h3").textContent = video.title;
  const actions = document.createElement("div");
  actions.className = "card-actions";
  const remove = document.createElement("button");
  remove.type = "button";
  remove.className = "btn delete-video";
  remove.textContent = "Удалить";
  remove.setAttribute("aria-label", `Удалить видео «${video.title}»`);
  remove.disabled = video.status === "uploaded" || video.status === "processing";
  if (remove.disabled) remove.title = "Удаление доступно после завершения обработки";
  remove.onclick = (event) => {
    event.stopPropagation();
    deleteVideo(video, remove);
  };
  actions.append(remove);
  card.append(actions);
  if (video.status === "ready") card.onclick = () => play(video);
  return card;
}

async function deleteVideo(video, button) {
  if (!window.confirm(`Удалить видео «${video.title}»? Исходник и обработанные файлы будут удалены.`)) return;
  button.disabled = true;
  button.textContent = "Удаление…";
  try {
    const response = await fetch(`/api/videos/${video.id}`, { method: "DELETE" });
    if (!response.ok && response.status !== 404) {
      const detail = await response.json().catch(() => ({}));
      throw new Error(detail.detail || `Ошибка ${response.status}`);
    }
    if (state.playingId === video.id) {
      const player = $("player");
      player.pause();
      if (state.hls) state.hls.destroy();
      state.hls = null;
      state.playingId = null;
      player.removeAttribute("src");
      player.load();
      $("player-section").hidden = true;
    }
  } catch (err) {
    window.alert(`Не удалось удалить видео: ${err.message}`);
    button.disabled = false;
    button.textContent = "Удалить";
    return;
  }
  button.closest(".card").remove();
  try {
    await loadFeed();
  } catch {
    window.alert("Видео удалено. Обновите страницу, чтобы обновить список.");
  }
}

async function loadFeed() {
  clearTimeout(state.feedTimer);
  const request = ++state.feedRequest;
  const query = state.category ? `?category=${state.category}` : "";
  const videos = await api(`/videos${query}`);
  if (request !== state.feedRequest) return;
  $("feed").replaceChildren(...videos.map(videoCard));
  $("feed-empty").hidden = videos.length > 0;
  $("feed-count").textContent = videos.length ? `${videos.length} шт.` : "";
  // Пока есть необработанные ролики — обновляем ленту, чтобы показать смену статуса
  if (videos.some((v) => v.status === "uploaded" || v.status === "processing")) {
    state.feedTimer = setTimeout(loadFeed, 3000);
  }
}

function play(video) {
  state.playingId = video.id;
  const player = $("player");
  $("player-section").hidden = false;
  $("player-title").textContent = video.title;
  $("player-info").textContent = `${video.category_name} · ${formatDuration(video.duration_sec)}`;
  $("player-description").textContent = video.description;

  if (state.hls) state.hls.destroy();
  if (window.Hls && Hls.isSupported()) {
    state.hls = new Hls();
    state.hls.loadSource(video.hls_url);
    state.hls.attachMedia(player);
  } else {
    player.src = video.hls_url; // Safari воспроизводит HLS нативно
  }
  player.play().catch(() => {});
  window.scrollTo({ top: 0, behavior: "smooth" });
}

function upload(event) {
  event.preventDefault();
  const form = event.target;
  const progress = $("upload-progress");
  const xhr = new XMLHttpRequest();
  xhr.open("POST", "/api/videos");
  xhr.upload.onprogress = (e) => {
    if (e.lengthComputable) progress.value = (e.loaded / e.total) * 100;
  };
  xhr.onload = () => {
    if (xhr.status === 201) {
      $("upload-status").textContent = "Загружено, видео поставлено в очередь на обработку";
      form.reset();
      setTimeout(() => $("upload-dialog").close(), 800);
      loadFeed();
    } else {
      $("upload-status").textContent = `Ошибка: ${xhr.responseText}`;
    }
    progress.hidden = true;
  };
  xhr.onerror = () => {
    $("upload-status").textContent = "Сеть недоступна";
    progress.hidden = true;
  };
  progress.hidden = false;
  progress.value = 0;
  $("upload-status").textContent = "Загрузка…";
  xhr.send(new FormData(form));
}

async function init() {
  $("open-upload").onclick = () => {
    $("upload-status").textContent = "";
    $("upload-dialog").showModal();
  };
  $("close-upload").onclick = () => $("upload-dialog").close();
  $("upload-form").onsubmit = upload;

  try {
    state.categories = await api("/categories");
    renderCategories();
    await loadFeed();
  } catch (err) {
    $("feed-empty").hidden = false;
    $("feed-empty").textContent = `API недоступен: ${err.message}`;
  }
}

init();
