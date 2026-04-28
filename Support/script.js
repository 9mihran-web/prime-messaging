const menuToggle = document.querySelector('.menu-toggle');
const nav = document.querySelector('.main-nav');
const navLinks = document.querySelectorAll('.main-nav a');

function closeMenu() {
  if (!nav || !menuToggle) return;
  nav.classList.remove('open');
  menuToggle.setAttribute('aria-expanded', 'false');
}

if (menuToggle && nav) {
  menuToggle.addEventListener('click', () => {
    const isOpen = nav.classList.toggle('open');
    menuToggle.setAttribute('aria-expanded', String(isOpen));
  });

  navLinks.forEach((link) => {
    link.addEventListener('click', () => {
      closeMenu();
    });
  });

  document.addEventListener('click', (event) => {
    const target = event.target;
    if (!(target instanceof Element)) return;

    const clickedInsideMenu = target.closest('.main-nav') || target.closest('.menu-toggle');
    if (!clickedInsideMenu) {
      closeMenu();
    }
  });

  document.addEventListener('keydown', (event) => {
    if (event.key === 'Escape') {
      closeMenu();
    }
  });
}

const pageKey = document.body.dataset.page;
if (pageKey) {
  const activeLink = document.querySelector(`.main-nav [data-nav="${pageKey}"]`);
  if (activeLink instanceof HTMLElement) {
    activeLink.classList.add('active');
  }
}

const revealItems = document.querySelectorAll('.section-reveal');

if ('IntersectionObserver' in window) {
  const revealObserver = new IntersectionObserver(
    (entries, observer) => {
      entries.forEach((entry) => {
        if (!entry.isIntersecting) return;
        entry.target.classList.add('is-visible');
        observer.unobserve(entry.target);
      });
    },
    { threshold: 0.15 }
  );

  revealItems.forEach((item) => revealObserver.observe(item));
} else {
  revealItems.forEach((item) => item.classList.add('is-visible'));
}

const counters = document.querySelectorAll('[data-count]');

function animateCounter(element) {
  const target = Number(element.dataset.count || 0);
  const duration = 1200;
  const startTime = performance.now();

  const updateCounter = (now) => {
    const elapsed = now - startTime;
    const progress = Math.min(elapsed / duration, 1);
    const eased = 1 - Math.pow(1 - progress, 3);
    const current = Math.floor(target * eased);
    element.textContent = String(current);

    if (progress < 1) {
      requestAnimationFrame(updateCounter);
    } else {
      element.textContent = String(target);
    }
  };

  requestAnimationFrame(updateCounter);
}

if ('IntersectionObserver' in window && counters.length > 0) {
  const counterObserver = new IntersectionObserver(
    (entries, observer) => {
      entries.forEach((entry) => {
        if (!entry.isIntersecting) return;
        animateCounter(entry.target);
        observer.unobserve(entry.target);
      });
    },
    { threshold: 0.5 }
  );

  counters.forEach((counter) => counterObserver.observe(counter));
} else {
  counters.forEach((counter) => {
    counter.textContent = counter.dataset.count || '0';
  });
}

const accordionButtons = document.querySelectorAll('.accordion-item button');

accordionButtons.forEach((button) => {
  button.addEventListener('click', () => {
    const item = button.closest('.accordion-item');
    if (!item) return;

    const content = item.querySelector('.accordion-content');
    const isOpen = item.classList.contains('open');

    document.querySelectorAll('.accordion-item.open').forEach((openItem) => {
      openItem.classList.remove('open');
      const openButton = openItem.querySelector('button');
      const openContent = openItem.querySelector('.accordion-content');
      if (openButton) openButton.setAttribute('aria-expanded', 'false');
      if (openContent) openContent.style.maxHeight = '';
    });

    if (!isOpen) {
      item.classList.add('open');
      button.setAttribute('aria-expanded', 'true');
      if (content instanceof HTMLElement) {
        content.style.maxHeight = `${content.scrollHeight}px`;
      }
    }
  });
});

const contactForm = document.querySelector('.contact-form');
const formStatus = document.querySelector('.form-status');

if (contactForm instanceof HTMLFormElement && formStatus instanceof HTMLElement) {
  const locale = (document.documentElement.lang || 'en').toLowerCase().startsWith('ru') ? 'ru' : 'en';
  const copy = {
    ru: {
      invalid: 'Проверьте поля формы: заполните обязательные данные корректно.',
      sending: 'Отправка...',
      success: 'Сообщение отправлено. Мы получили вашу заявку и свяжемся с вами по email.',
      fallback: 'Не удалось отправить сообщение. Попробуйте ещё раз чуть позже.',
      endpointMissing: 'Форма поддержки на сервере пока не активна. Нужно обновить backend.',
      mailNotConfigured: 'Форма подключена, но почта поддержки на сервере ещё не настроена.',
      invalidEmail: 'Укажите корректный email, чтобы мы могли ответить вам.',
      invalidMessage: 'Опишите проблему чуть подробнее. Сообщение должно быть не слишком коротким.',
    },
    en: {
      invalid: 'Please check the form fields and complete the required information correctly.',
      sending: 'Sending...',
      success: 'Your message has been sent. We received your request and will get back to you by email.',
      fallback: 'We could not send your message right now. Please try again a little later.',
      endpointMissing: 'The support form endpoint is not active on the server yet. The backend needs to be updated.',
      mailNotConfigured: 'The support form is connected, but outgoing support email is not configured on the server yet.',
      invalidEmail: 'Please enter a valid email address so we can reply to you.',
      invalidMessage: 'Please describe the problem in a bit more detail. The message is too short.',
    },
  };
  const endpoint =
    contactForm.dataset.endpoint ||
    contactForm.getAttribute('action') ||
    'https://prime-messaging-production.up.railway.app/support/contact';

  contactForm.addEventListener('submit', (event) => {
    event.preventDefault();

    if (!contactForm.checkValidity()) {
      formStatus.className = 'form-status error';
      formStatus.textContent = copy[locale].invalid;
      contactForm.reportValidity();
      return;
    }

    formStatus.className = 'form-status';
    formStatus.textContent = copy[locale].sending;

    const submitButton = contactForm.querySelector('button[type="submit"]');
    if (submitButton instanceof HTMLButtonElement) {
      submitButton.disabled = true;
      submitButton.style.opacity = '0.72';
    }

    const formData = new FormData(contactForm);
    const payload = {
      name: String(formData.get('name') || '').trim(),
      email: String(formData.get('email') || '').trim(),
      subject: String(formData.get('subject') || formData.get('company') || '').trim(),
      message: String(formData.get('message') || '').trim(),
      locale,
      page_url: window.location.href,
    };

    fetch(endpoint, {
      method: 'POST',
      headers: {
        'Content-Type': 'application/json',
      },
      body: JSON.stringify(payload),
    })
      .then(async (response) => {
        const responseBody = await response.json().catch(() => ({}));
        if (!response.ok) {
          const error = new Error(`support_form_http_${response.status}`);
          error.status = response.status;
          error.payload = responseBody;
          throw error;
        }
        return responseBody;
      })
      .then(() => {
        formStatus.className = 'form-status success';
        formStatus.textContent = copy[locale].success;
        contactForm.reset();
      })
      .catch((error) => {
        const status = error?.status;
        const backendError = error?.payload?.error;
        let message = copy[locale].fallback;

        if (status === 404) {
          message = copy[locale].endpointMissing;
        } else if (backendError === 'support_email_not_configured') {
          message = copy[locale].mailNotConfigured;
        } else if (backendError === 'invalid_email') {
          message = copy[locale].invalidEmail;
        } else if (backendError === 'invalid_message') {
          message = copy[locale].invalidMessage;
        }

        formStatus.className = 'form-status error';
        formStatus.textContent = message;
      })
      .finally(() => {
        if (submitButton instanceof HTMLButtonElement) {
          submitButton.disabled = false;
          submitButton.style.opacity = '';
        }
      });
  });
}

const yearElement = document.getElementById('year');
if (yearElement) {
  yearElement.textContent = String(new Date().getFullYear());
}
