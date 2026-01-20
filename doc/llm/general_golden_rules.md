1. clean separation of concerns in modules 
2. prefer reusable pure functions over complex classes / modules 
3. all functions/classes/methods need doc strings. Write them so that even junior developers will understand purpose and flow 
4. No magic numbers - use proper settings/configurations module(s) 
5. All outside facing functions/classes/methods need proper unit tests 
6. No truncation of data: Never truncate data unless explicitly specified by the user. NEVER introduce truncation before consulting with the team and getting approval. 
7. All network / LLM / API calls that could fail or time out need proper retry functionality with exponential backoff 
8. All errors must be handled, logged, and reported to the user: No exceptions. 
9. when using less familiar external libraries / APIs, research their documentation first to ensure correct use
10. always keep cross platform compatibility in mind when thinking about solutions 