'use client';

import { useState, useRef, useEffect } from 'react';
import { Send, Stethoscope, User, Info, Phone, FlaskConical } from 'lucide-react';

interface Message {
    id: string;
    role: 'user' | 'assistant';
    content: string;
    timestamp: Date;
}

type Fields = Record<string, string>;

type ContentPart =
    | { type: 'text'; value: string }
    | { type: 'doctor'; fields: Fields }
    | { type: 'tests'; items: Fields[] };

const API_URL = process.env.NEXT_PUBLIC_API_URL || 'http://localhost:8000';

const SUGGESTIONS = [
    'I have a fever, which doctor should I see?',
    'Which doctor treats skin problems?',
    'What tests do you offer and how much do they cost?',
    'How do I book an appointment?',
];

// Card lines emitted by the backend, e.g.
//   Doctor | Name: Dr. X | Specialty: Y | Ward: Z | Hours: ... | Booking: ...
//   Test | Name: CBC | Price: ৳400
const CARD_LINE = /^(Doctor|Test)\s*\|(.+)$/i;

function parseFields(rest: string): Fields {
    const fields: Fields = {};
    for (const segment of rest.split('|')) {
        const idx = segment.indexOf(':');
        if (idx === -1) continue;
        const key = segment.slice(0, idx).trim().toLowerCase();
        const value = segment.slice(idx + 1).trim();
        if (key && value) fields[key] = value;
    }
    return fields;
}

function cleanText(value: string): string {
    // The model is told not to use markdown; strip any that slips through.
    return value.replace(/\*\*(.+?)\*\*/g, '$1').replace(/^#+\s*/gm, '');
}

function parseMessageContent(content: string): ContentPart[] {
    const parts: ContentPart[] = [];
    let textBuffer: string[] = [];

    const flushText = () => {
        if (textBuffer.length > 0) {
            const value = cleanText(textBuffer.join('\n').trim());
            if (value) parts.push({ type: 'text', value });
            textBuffer = [];
        }
    };

    for (const rawLine of content.split('\n')) {
        const line = rawLine.trim().replace(/^[-*•]\s+/, '').replace(/\*\*/g, '');
        const match = line.match(CARD_LINE);
        if (!match) {
            textBuffer.push(rawLine);
            continue;
        }

        const fields = parseFields(match[2]);
        if (!fields.name) {
            textBuffer.push(rawLine);
            continue;
        }

        flushText();
        if (match[1].toLowerCase() === 'doctor') {
            parts.push({ type: 'doctor', fields });
        } else {
            // Group consecutive tests into one list
            const last = parts[parts.length - 1];
            if (last && last.type === 'tests') {
                last.items.push(fields);
            } else {
                parts.push({ type: 'tests', items: [fields] });
            }
        }
    }
    flushText();

    return parts;
}

const DOCTOR_BADGES: { key: string; className: string }[] = [
    { key: 'specialty', className: 'bg-slate-900 text-white' },
    { key: 'degree', className: 'bg-violet-600 text-white' },
    { key: 'ward', className: 'bg-amber-600 text-white' },
    { key: 'hours', className: 'bg-sky-600 text-white' },
    { key: 'fee', className: 'bg-emerald-600 text-white' },
];

function DoctorCard({ fields }: { fields: Fields }) {
    const booking = fields.booking;
    return (
        <div className="rounded-xl border border-teal-100 bg-gradient-to-br from-teal-50/70 to-white p-3">
            <p className="text-sm font-semibold text-slate-900">{fields.name}</p>
            <div className="mt-2 flex flex-wrap gap-1.5">
                {DOCTOR_BADGES.filter(({ key }) => fields[key]).map(({ key, className }) => (
                    <span
                        key={key}
                        className={`rounded-md px-2 py-0.5 text-[11px] font-medium ${className}`}
                    >
                        {key === 'fee' ? `Fee: ${fields[key]}` : fields[key]}
                    </span>
                ))}
            </div>
            {booking && (
                <a
                    href={`tel:${booking.replace(/[^\d+]/g, '')}`}
                    className="mt-2.5 inline-flex items-center gap-1.5 rounded-full border border-teal-200 bg-white px-2.5 py-1 text-xs font-medium text-teal-700 transition-colors hover:bg-teal-50"
                >
                    <Phone className="h-3.5 w-3.5" />
                    Book: {booking}
                </a>
            )}
        </div>
    );
}

function TestList({ items }: { items: Fields[] }) {
    return (
        <div className="flex flex-col gap-1.5">
            {items.map((item, idx) => (
                <div
                    key={`${item.name}-${idx}`}
                    className="flex items-center justify-between gap-3 rounded-lg border border-emerald-100 bg-emerald-50/50 px-3 py-2"
                >
                    <span className="flex min-w-0 items-center gap-2 text-xs font-medium text-slate-800">
                        <FlaskConical className="h-3.5 w-3.5 flex-shrink-0 text-emerald-600" />
                        {item.name}
                    </span>
                    {item.price && (
                        <span className="flex-shrink-0 rounded-full bg-emerald-600 px-2 py-0.5 text-[11px] font-semibold text-white">
                            {item.price}
                        </span>
                    )}
                </div>
            ))}
        </div>
    );
}

function AssistantAvatar({ size = 'sm' }: { size?: 'sm' | 'lg' }) {
    const dims = size === 'lg' ? 'h-10 w-10' : 'h-7 w-7';
    const icon = size === 'lg' ? 'h-5 w-5' : 'h-3.5 w-3.5';
    return (
        <div
            className={`flex ${dims} flex-shrink-0 items-center justify-center rounded-full bg-gradient-to-br from-teal-500 to-sky-600 text-white shadow-sm`}
        >
            <Stethoscope className={icon} />
        </div>
    );
}

export default function ClinicMate() {
    const [messages, setMessages] = useState<Message[]>([]);
    const [input, setInput] = useState('');
    const [isLoading, setIsLoading] = useState(false);
    const [sessionId, setSessionId] = useState<string>('');
    const messagesContainerRef = useRef<HTMLDivElement>(null);
    const inputRef = useRef<HTMLInputElement>(null);

    const scrollToBottom = () => {
        const el = messagesContainerRef.current;
        if (!el) return;
        el.scrollTo({ top: el.scrollHeight, behavior: 'smooth' });
    };

    useEffect(() => {
        scrollToBottom();
    }, [messages, isLoading]);

    const sendMessage = async (text?: string) => {
        const content = (text ?? input).trim();
        if (!content || isLoading) return;

        const userMessage: Message = {
            id: crypto.randomUUID(),
            role: 'user',
            content,
            timestamp: new Date(),
        };

        setMessages(prev => [...prev, userMessage]);
        setInput('');
        setIsLoading(true);

        try {
            const response = await fetch(`${API_URL}/chat`, {
                method: 'POST',
                headers: {
                    'Content-Type': 'application/json',
                },
                body: JSON.stringify({
                    message: content,
                    session_id: sessionId || undefined,
                }),
            });

            if (!response.ok) throw new Error('Failed to send message');

            const data = await response.json();

            if (!sessionId) {
                setSessionId(data.session_id);
            }

            const assistantMessage: Message = {
                id: crypto.randomUUID(),
                role: 'assistant',
                content: data.response,
                timestamp: new Date(),
            };

            setMessages(prev => [...prev, assistantMessage]);
        } catch (error) {
            console.error('Error:', error);
            const errorMessage: Message = {
                id: crypto.randomUUID(),
                role: 'assistant',
                content: 'Sorry, I could not reach the clinic assistant right now. Please try again in a moment, or call the clinic directly.',
                timestamp: new Date(),
            };
            setMessages(prev => [...prev, errorMessage]);
        } finally {
            setIsLoading(false);
            inputRef.current?.focus();
        }
    };

    const handleKeyPress = (e: React.KeyboardEvent) => {
        if (e.key === 'Enter' && !e.shiftKey) {
            e.preventDefault();
            sendMessage();
        }
    };

    return (
        <div className="flex h-full w-full flex-col overflow-hidden bg-white">
            {/* Header */}
            <header className="flex flex-shrink-0 items-center gap-3 border-b border-slate-200 bg-white/90 px-4 py-3 backdrop-blur sm:px-6">
                <div className="relative flex-shrink-0">
                    <AssistantAvatar size="lg" />
                    <span className="absolute -bottom-0.5 -right-0.5 block h-3 w-3 rounded-full border-2 border-white bg-emerald-500" />
                </div>
                <div className="min-w-0 flex-1">
                    <h1 className="truncate text-base font-semibold text-slate-900">ClinicMate</h1>
                    <p className="truncate text-xs text-slate-500">
                        Online &middot; Ask about doctors, services &amp; appointments
                    </p>
                </div>
            </header>

            {/* Messages */}
            <div
                ref={messagesContainerRef}
                className="scrollbar-thin flex-1 overflow-y-auto px-4 py-6 sm:px-6"
            >
                <div className="mx-auto flex w-full max-w-2xl flex-col gap-4">
                    {messages.length === 0 && (
                        <div className="flex flex-1 flex-col items-center justify-center px-4 py-10 text-center">
                            <div className="mb-4 flex h-14 w-14 items-center justify-center rounded-2xl bg-teal-50 text-teal-600 ring-1 ring-inset ring-teal-100">
                                <Stethoscope className="h-6 w-6" />
                            </div>
                            <p className="text-sm font-medium text-slate-800">
                                Hi, I&apos;m ClinicMate &mdash; your clinic assistant.
                            </p>
                            <p className="mt-1 max-w-xs text-sm text-slate-500">
                                Describe your symptoms or ask about doctors, tests, prices and appointments.
                            </p>
                            <div className="mt-5 flex w-full max-w-sm flex-col gap-2">
                                {SUGGESTIONS.map((suggestion) => (
                                    <button
                                        key={suggestion}
                                        type="button"
                                        onClick={() => sendMessage(suggestion)}
                                        className="rounded-xl border border-slate-200 bg-slate-50 px-4 py-2.5 text-left text-sm text-slate-600 transition-colors hover:border-teal-300 hover:bg-teal-50 hover:text-teal-700"
                                    >
                                        {suggestion}
                                    </button>
                                ))}
                            </div>
                        </div>
                    )}

                    {messages.map((message) => (
                        <div
                            key={message.id}
                            className={`animate-message-in flex items-end gap-2.5 ${
                                message.role === 'user' ? 'justify-end' : 'justify-start'
                            }`}
                        >
                            {message.role === 'assistant' && <AssistantAvatar />}

                            <div
                                className={`max-w-[85%] rounded-2xl px-4 py-2.5 text-sm leading-relaxed shadow-sm sm:max-w-[75%] ${
                                    message.role === 'user'
                                        ? 'rounded-br-md bg-gradient-to-br from-teal-500 to-sky-600 text-white'
                                        : 'rounded-bl-md border border-slate-200 bg-white text-slate-800'
                                }`}
                            >
                                {message.role === 'assistant' ? (
                                    <div className="flex flex-col gap-2.5">
                                        {parseMessageContent(message.content).map((part, idx) => {
                                            if (part.type === 'text') {
                                                return (
                                                    <p key={idx} className="whitespace-pre-wrap">
                                                        {part.value}
                                                    </p>
                                                );
                                            }
                                            if (part.type === 'doctor') {
                                                return <DoctorCard key={idx} fields={part.fields} />;
                                            }
                                            return <TestList key={idx} items={part.items} />;
                                        })}
                                    </div>
                                ) : (
                                    <p className="whitespace-pre-wrap">{message.content}</p>
                                )}
                                <p
                                    className={`mt-1 text-[10px] ${
                                        message.role === 'user' ? 'text-teal-50/80' : 'text-slate-400'
                                    }`}
                                >
                                    {message.timestamp.toLocaleTimeString([], {
                                        hour: '2-digit',
                                        minute: '2-digit',
                                    })}
                                </p>
                            </div>

                            {message.role === 'user' && (
                                <div className="flex h-7 w-7 flex-shrink-0 items-center justify-center rounded-full bg-slate-700 text-white">
                                    <User className="h-3.5 w-3.5" />
                                </div>
                            )}
                        </div>
                    ))}

                    {isLoading && (
                        <div className="animate-message-in flex items-end gap-2.5 justify-start">
                            <AssistantAvatar />
                            <div className="rounded-2xl rounded-bl-md border border-slate-200 bg-white px-4 py-3 shadow-sm">
                                <div className="flex items-center gap-1.5">
                                    <span className="h-1.5 w-1.5 animate-bounce rounded-full bg-slate-400" />
                                    <span className="delay-100 h-1.5 w-1.5 animate-bounce rounded-full bg-slate-400" />
                                    <span className="delay-200 h-1.5 w-1.5 animate-bounce rounded-full bg-slate-400" />
                                </div>
                            </div>
                        </div>
                    )}
                </div>
            </div>

            {/* Input */}
            <div className="flex-shrink-0 border-t border-slate-200 bg-white px-4 py-3 sm:px-6">
                <div className="mx-auto w-full max-w-2xl">
                    <div className="flex items-center gap-2 rounded-full border border-slate-200 bg-slate-50 p-1.5 pl-4 transition-colors focus-within:border-teal-400 focus-within:bg-white focus-within:ring-2 focus-within:ring-teal-500/20">
                        <input
                            ref={inputRef}
                            type="text"
                            value={input}
                            onChange={(e) => setInput(e.target.value)}
                            onKeyDown={handleKeyPress}
                            placeholder="Type your message..."
                            maxLength={1000}
                            className="flex-1 bg-transparent text-sm text-slate-900 placeholder:text-slate-400 focus:outline-none"
                            disabled={isLoading}
                        />
                        <button
                            onClick={() => sendMessage()}
                            disabled={!input.trim() || isLoading}
                            aria-label="Send message"
                            className="flex h-9 w-9 flex-shrink-0 items-center justify-center rounded-full bg-gradient-to-br from-teal-500 to-sky-600 text-white shadow-sm transition-all hover:shadow-md disabled:cursor-not-allowed disabled:opacity-40 disabled:shadow-none"
                        >
                            <Send className="h-4 w-4" />
                        </button>
                    </div>
                    <p className="mt-2 flex items-center justify-center gap-1.5 text-center text-[11px] leading-snug text-slate-400">
                        <Info className="h-3 w-3 flex-shrink-0" />
                        Based on clinic info only, not medical advice. For emergencies, call your local emergency number.
                    </p>
                    <p className="mt-1.5 text-center text-[10px] text-slate-300">
                        Built by RIZS
                    </p>
                </div>
            </div>
        </div>
    );
}
